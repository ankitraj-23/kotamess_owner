// KotaMess Owner — WhatsApp chat import + request extraction Edge Function.
//
// POST { chatText, source: "paste"|"file", fileName?: string, today: "YYYY-MM-DD" }
// Requires a valid Supabase user JWT (sent automatically by the Flutter
// supabase client). The function owns the whole import pipeline server-side:
//
//   1. authenticate the user (owner_id == auth uid; NEVER trusted from client)
//   2. create a `chat_imports` row (status = processing)
//   3. parse WhatsApp-style messages and apply a default 90-day window
//   4. insert the processed messages into `chat_messages`
//   5. call Gemini server-side (rule-based fallback if unavailable)
//   6. resolve the customer (`students`) for each request (never auto-created)
//   7. insert extracted requests into `meal_requests` (status = pending)
//   8. deterministic duplicate detection -> `request_duplicates`
//   9. update `chat_imports` counts + final status, and return a summary
//
// Every write goes through the *user's* JWT, so RLS (owner_id = auth.uid())
// enforces isolation — no service_role key is ever used. The Gemini key is a
// server secret and never leaves the server / is never returned to the client.
//
// Vocabulary note: the section-6 enum names in the task brief (meal_cancel,
// full_day, breakfast, …) are NOT used — the live DB CHECK constraints enforce
// the existing app vocabulary (cancel_meal/add_meal/…, lunch/dinner/both/none,
// status pending/approved/rejected/completed/cancelled). We keep the existing
// vocabulary so inserts pass and the Requests review flow keeps working.
//
// Deploy:  supabase functions deploy extract-requests
// Secrets: supabase secrets set GEMINI_API_KEY=...
//          supabase secrets set GEMINI_MODEL=gemini-2.5-flash   (optional)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const REQUEST_TYPES = [
  "cancel_meal",
  "add_meal",
  "pause_mess",
  "resume_mess",
  "both_meals_cancel",
  "dues_query",
  "payment_note",
  "generic_note",
  "unclear",
];
const MEAL_TYPES = ["lunch", "dinner", "both", "none"];

const RETENTION_DAYS = 90;
const LOW_CONFIDENCE = 0.6;
// Fallback request cutoff when owner_profiles has no usable value (matches the
// migration default). Read the column first; never hardcode "60 minutes".
const DEFAULT_CUTOFF_MINUTES = 60;

interface ExtractedRequest {
  studentName: string;
  originalMessage: string;
  requestType: string;
  mealType: string;
  dateLabel: string;
  requestDate: string | null;
  confidence: number;
  reason: string;
}

interface ImportSummary {
  totalMessages: number;
  processedMessages: number;
  skippedOldMessages: number;
  extractedCount: number;
  duplicateCount: number;
  rejectedCount: number;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function emptySummary(): ImportSummary {
  return {
    totalMessages: 0,
    processedMessages: 0,
    skippedOldMessages: 0,
    extractedCount: 0,
    duplicateCount: 0,
    rejectedCount: 0,
  };
}

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ status: "failed", error: "Method not allowed.", summary: emptySummary(), warnings: [] }, 405);
  }

  // --- Auth: require a valid Supabase user JWT ---------------------------
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return json({ status: "failed", error: "Not authenticated.", summary: emptySummary(), warnings: [] }, 401);
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_ANON_KEY") ?? "",
    { global: { headers: { Authorization: authHeader } } },
  );

  let ownerId: string;
  try {
    const { data: userData, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userData?.user) {
      return json({ status: "failed", error: "Invalid or expired session.", summary: emptySummary(), warnings: [] }, 401);
    }
    ownerId = userData.user.id;
  } catch (_e) {
    return json({ status: "failed", error: "Auth check failed.", summary: emptySummary(), warnings: [] }, 401);
  }

  // --- Parse body -------------------------------------------------------
  let body: { chatText?: unknown; source?: unknown; fileName?: unknown; today?: unknown } | null = null;
  try {
    body = await req.json();
  } catch (_e) {
    return json({ status: "failed", error: "Request body was not valid JSON.", summary: emptySummary(), warnings: [] }, 400);
  }

  const chatText = typeof body?.chatText === "string" ? body.chatText : "";
  if (chatText.trim() === "") {
    return json({ status: "failed", error: "No chat text provided.", summary: emptySummary(), warnings: [] }, 400);
  }
  const source = body?.source === "file" ? "file" : "paste";
  const fileName = typeof body?.fileName === "string" && body.fileName.trim() !== ""
    ? body.fileName.trim()
    : null;
  const today =
    typeof body?.today === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.today)
      ? body.today
      : new Date().toISOString().slice(0, 10);

  // --- Create the import run (status = processing) ----------------------
  let importId: string | null = null;
  try {
    const { data: imp, error: impErr } = await supabase
      .from("chat_imports")
      .insert({
        owner_id: ownerId,
        source: source === "file" ? "whatsapp_file" : "text_upload",
        file_name: fileName,
        imported_text_hash: simpleHash(chatText),
        status: "processing",
      })
      .select("id")
      .single();
    if (impErr || !imp) throw impErr ?? new Error("Could not create import.");
    importId = imp.id as string;
  } catch (_e) {
    return json({ status: "failed", error: "Could not start the import.", summary: emptySummary(), warnings: [] }, 200);
  }

  const warnings: string[] = [];
  try {
    // --- Parse + 90-day window -----------------------------------------
    const parsed = parseWhatsApp(chatText);
    const cutoffMs = Date.parse(today + "T00:00:00Z") - RETENTION_DAYS * 86_400_000;

    const processed: ChatMessage[] = [];
    let skippedOld = 0;
    for (const m of parsed) {
      const ts = parseTimestamp(m.dateText);
      if (ts && ts.getTime() < cutoffMs) {
        skippedOld++; // old message with a real timestamp — outside the window
        continue;
      }
      processed.push(m);
    }

    const totalMessages = parsed.length;
    const processedMessages = processed.length;

    // --- Persist the processed messages --------------------------------
    // text_message -> id, used later to link meal_requests.message_id.
    const messageIdByText = new Map<string, string>();
    // text_message -> parsed receipt time, used for the late-request cutoff
    // check below. First occurrence wins (mirrors messageIdByText).
    const messageTsByText = new Map<string, Date>();
    if (processed.length > 0) {
      const rows = processed.map((m) => {
        const ts = parseTimestamp(m.dateText);
        if (ts && !messageTsByText.has(m.text)) messageTsByText.set(m.text, ts);
        return {
          owner_id: ownerId,
          import_id: importId,
          sender_name: cleanSender(m.sender),
          message_text: m.text,
          message_timestamp: ts ? ts.toISOString() : null,
          message_hash: simpleHash(m.sender + "|" + m.text),
          is_customer_message: true,
          is_processed: true,
        };
      });
      const { data: inserted, error: msgErr } = await supabase
        .from("chat_messages")
        .insert(rows)
        .select("id, message_text");
      if (msgErr) throw msgErr;
      for (const r of inserted ?? []) {
        const text = r.message_text as string;
        if (!messageIdByText.has(text)) messageIdByText.set(text, r.id as string);
      }
    }

    // --- Extract (Gemini, fallback to rule-based) ----------------------
    // Only the in-window messages are sent for extraction.
    const filteredText = processed
      .map((m) => (m.dateText ? `${m.dateText} - ` : "") + `${m.sender}: ${m.text}`)
      .join("\n");

    const geminiKey = Deno.env.get("GEMINI_API_KEY");
    const geminiModel = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";
    let requests: ExtractedRequest[] | null = null;
    if (geminiKey && filteredText.trim() !== "") {
      try {
        requests = await extractWithGemini(geminiKey, geminiModel, filteredText, today);
      } catch (_e) {
        warnings.push("Gemini extraction failed; used fallback parser.");
        requests = null;
      }
    } else if (!geminiKey) {
      warnings.push("GEMINI_API_KEY not set; used fallback parser.");
    }
    if (requests === null) {
      requests = fallbackExtract(processed, today);
    }

    // --- Resolve customers (students) ----------------------------------
    // Per distinct sender, decide link_status (linked / needs_review /
    // ambiguous / unreliable_sender), the linked student id (only when
    // confident), and the candidate ids the owner can choose from in review.
    const senderInfo = await resolveSenders(
      supabase,
      ownerId,
      requests.map((r) => r.studentName),
    );

    // --- Duplicate detection (deterministic, no embeddings) ------------
    // Identity is student-aware:
    //   linked   (student_id present) -> student_id + action + meal + date, so
    //            two different people who share a name never collide.
    //   unlinked (student_id null / ambiguous) -> sender + action + meal + date
    //            + EXACT original message, so two different unlinked "Amit"s
    //            with different messages are NOT flagged; only a re-import of
    //            the same message is. Match against recent existing requests,
    //            then against earlier rows in this batch.
    const existingByKey = await loadExistingDupKeys(supabase, ownerId);
    const batchFirstIndexByKey = new Map<string, number>();

    // --- Late-request cutoff settings (owner_profiles) -----------------
    // Meal serving times + the minutes-before-meal window. Read once; missing
    // profile / values fall back to safe defaults and simply skip flagging.
    const cutoffSettings = await loadCutoffSettings(supabase, ownerId);

    interface PendingDup {
      index: number;
      duplicateOf: string | null; // existing meal_requests.id, or null = within-batch
      batchIndex: number | null; // earlier index in this batch, or null = existing
      linked: boolean; // true = matched on student_id; false = matched on exact message
    }
    const dupPlans: PendingDup[] = [];

    const rows = requests.map((r, i) => {
      const sKey = nameKey(r.studentName);
      const info = senderInfo.get(sKey) ?? {
        status: "needs_review" as const,
        studentId: null,
        candidateIds: [] as string[],
        reason: "No matching customer found — please review.",
      };
      const linkedId = info.studentId;
      // Confidently linked -> identity is the student_id. Unlinked / ambiguous
      // -> identity requires the exact original message (see key helpers).
      const linked = linkedId !== null;
      const key = linked ? linkedDupKey(linkedId, r) : unlinkedDupKey(sKey, r);
      let duplicateStatus = "unique";

      const existingId = existingByKey.get(key);
      const earlierIndex = batchFirstIndexByKey.get(key);
      if (existingId) {
        duplicateStatus = "possible_duplicate";
        dupPlans.push({ index: i, duplicateOf: existingId, batchIndex: null, linked });
      } else if (earlierIndex !== undefined) {
        duplicateStatus = "possible_duplicate";
        dupPlans.push({ index: i, duplicateOf: null, batchIndex: earlierIndex, linked });
      } else {
        batchFirstIndexByKey.set(key, i);
      }

      // Late-request flagging. Never auto-rejects: status stays "pending"
      // (needs review); the owner still confirms/rejects manually.
      const late = computeLate(
        r.mealType,
        r.requestDate,
        messageTsByText.get(r.originalMessage) ?? null,
        cutoffSettings,
      );

      return {
        owner_id: ownerId,
        student_id: linkedId,
        student_name: r.studentName,
        original_message: r.originalMessage,
        request_type: r.requestType,
        meal_type: r.mealType,
        request_date: r.requestDate,
        date_label: r.dateLabel,
        status: "pending", // confidence<0.6 / unclear / ambiguous are also pending (needs review)
        confidence: r.confidence,
        reason: r.reason,
        // Sender-linking metadata (0011). Drives the ambiguous-sender review flow.
        sender_raw: r.studentName,
        sender_normalized: sKey,
        link_status: info.status,
        link_reason: info.reason,
        candidate_student_ids: info.candidateIds.length > 0 ? info.candidateIds : null,
        source,
        import_id: importId,
        message_id: messageIdByText.get(r.originalMessage) ?? null,
        duplicate_status: duplicateStatus,
        is_late_request: late.isLate,
        cutoff_at: late.cutoffAt,
        message_received_at: late.messageReceivedAt,
        late_reason: late.lateReason,
      };
    });

    // --- Insert the extracted requests ---------------------------------
    let insertedIds: string[] = [];
    if (rows.length > 0) {
      const { data: insertedReqs, error: reqErr } = await supabase
        .from("meal_requests")
        .insert(rows)
        .select("id");
      if (reqErr) throw reqErr;
      insertedIds = (insertedReqs ?? []).map((r) => r.id as string);
    }

    // --- Record the duplicate links ------------------------------------
    let duplicateCount = 0;
    if (dupPlans.length > 0 && insertedIds.length === rows.length) {
      const dupRows = dupPlans
        .map((p) => {
          const dupOf = p.duplicateOf ?? (p.batchIndex !== null ? insertedIds[p.batchIndex] : null);
          if (!dupOf) return null;
          return {
            owner_id: ownerId,
            request_id: insertedIds[p.index],
            duplicate_of_request_id: dupOf,
            reason: p.linked
              ? "Same customer, meal, action and date as an earlier request."
              : "Identical message from the same sender as an earlier request (unlinked).",
            similarity_score: 1.0,
          };
        })
        .filter((r): r is NonNullable<typeof r> => r !== null);
      if (dupRows.length > 0) {
        const { error: dupErr } = await supabase.from("request_duplicates").insert(dupRows);
        if (dupErr) throw dupErr;
        duplicateCount = dupRows.length;
      }
    }

    // --- Counts + final status -----------------------------------------
    const rejectedCount = requests.filter(
      (r) => r.requestType === "unclear" || r.confidence < LOW_CONFIDENCE,
    ).length;

    const timestamps = processed
      .map((m) => parseTimestamp(m.dateText))
      .filter((d): d is Date => d !== null)
      .map((d) => d.toISOString().slice(0, 10))
      .sort();

    const summary: ImportSummary = {
      totalMessages,
      processedMessages,
      skippedOldMessages: skippedOld,
      extractedCount: insertedIds.length,
      duplicateCount,
      rejectedCount,
    };

    await supabase
      .from("chat_imports")
      .update({
        total_messages: summary.totalMessages,
        processed_messages: summary.processedMessages,
        skipped_old_messages: summary.skippedOldMessages,
        extracted_count: summary.extractedCount,
        duplicate_count: summary.duplicateCount,
        rejected_count: summary.rejectedCount,
        import_start_date: timestamps.length ? timestamps[0] : null,
        import_end_date: timestamps.length ? timestamps[timestamps.length - 1] : null,
        status: "completed",
      })
      .eq("id", importId)
      .eq("owner_id", ownerId);

    return json({ importId, status: "completed", summary, warnings }, 200);
  } catch (e) {
    // Mark the import failed and return a useful message to the client.
    const message = e instanceof Error ? e.message : "Import failed.";
    try {
      await supabase
        .from("chat_imports")
        .update({ status: "failed", error_message: message.slice(0, 500) })
        .eq("id", importId)
        .eq("owner_id", ownerId);
    } catch (_e) {
      // best-effort; nothing more we can do here.
    }
    return json(
      { importId, status: "failed", error: "Import failed while processing. Please try again.", summary: emptySummary(), warnings },
      200,
    );
  }
});

// ---------------------------------------------------------------------------
// Customer (students) resolution — ports lib/services/name_utils.dart +
// DatabaseService._resolveStudentIds so server matching == client matching.
// ---------------------------------------------------------------------------
const NAME_NOISE = new Set(["bhai", "bhaiya", "bhaisaab", "ji", "sir", "madam", "mess"]);

function nameKey(raw: string): string {
  const cleaned = raw
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (cleaned === "") return "";
  return cleaned.split(" ").filter((t) => !NAME_NOISE.has(t)).join(" ");
}

// Normalize a sender string to a 10-digit Indian phone "core", or "" when the
// string isn't phone-shaped. Lets an unsaved-contact sender (e.g. a raw number)
// match a student's stored phone. Names like "Amit" reduce to "" (no digits).
function phoneKey(raw: string): string {
  let d = (raw ?? "").replace(/\D/g, "");
  if (d.length === 12 && d.startsWith("91")) d = d.slice(2);
  else if (d.length === 11 && d.startsWith("0")) d = d.slice(1);
  return d.length === 10 ? d : "";
}

// A student is matchable only when active. `status` (active/inactive/paused) is
// authoritative when present; fall back to the legacy `active` boolean.
function isActiveStudent(s: { status?: unknown; active?: unknown }): boolean {
  if (typeof s.status === "string" && s.status !== "") return s.status === "active";
  return s.active !== false;
}

function pushId(map: Map<string, string[]>, key: string, id: string): void {
  const arr = map.get(key);
  if (arr) {
    if (!arr.includes(id)) arr.push(id);
  } else {
    map.set(key, [id]);
  }
}

// One sender's resolution, keyed by nameKey in the map returned below.
interface SenderInfo {
  // linked: auto-linked confidently. needs_review: no confident match.
  // ambiguous: >1 active customer shares the saved name (duplicate "Rahul").
  // unreliable_sender: empty / "null" / symbol- or emoji-only / too little text.
  status: "linked" | "needs_review" | "ambiguous" | "unreliable_sender";
  studentId: string | null; // set only when status === "linked"
  candidateIds: string[]; // customers the owner can pick from (ambiguous/review)
  reason: string; // human-readable explanation (stored in link_reason)
}

// A WhatsApp export only yields a real phone number for UNSAVED contacts; for
// saved contacts it yields the owner's saved NAME. These senders carry no
// usable identity and must NEVER auto-link or spawn a customer.
function isUnreliableSender(raw: string): boolean {
  const t = (raw ?? "").trim();
  if (t === "") return true;
  const low = t.toLowerCase();
  if (["null", "undefined", "unknown", "n/a", "na", "none"].includes(low)) {
    return true;
  }
  // Symbol-only / emoji-only / barely-any text: too little to identify a person.
  const alnum = low.replace(/[^a-z0-9]/g, "");
  return alnum.length < 2;
}

// Production-safe sender resolution. Returns, per distinct normalized sender,
// the link_status the request should carry plus any candidate customers.
//
// Priority per distinct sender:
//   0. Unreliable sender (empty/"null"/symbol/emoji) -> unreliable_sender; no
//      link, no customer created.
//   1. Phone-shaped sender:
//        - exactly one active customer with that phone -> linked
//        - >1 -> ambiguous (candidates)
//        - 0  -> needs_review (NEVER create a customer named after a number)
//   2. Saved alias -> exactly one active customer -> linked; >1 -> ambiguous.
//   3. Unique normalized name -> exactly one active customer -> linked.
//   4. >1 active customer share the name (the duplicate "Rahul") -> ambiguous:
//      student_id stays null, candidates listed, owner resolves manually.
//   5. No exact active match -> needs_review, student_id stays null. We NEVER
//      auto-create a customer from a chat sender name (a spelling variant would
//      silently duplicate a real student). Fuzzy lookalikes are attached as
//      candidate suggestions only; the owner links manually in the review flow.
//
// Fuzzy/partial similarity is NEVER used to auto-link and NEVER creates a
// customer — it only powers review suggestions. We never persist a generic
// ambiguous name like "Rahul" as an alias when multiple active customers match.
async function resolveSenders(
  supabase: SupabaseClient,
  ownerId: string,
  names: string[],
): Promise<Map<string, SenderInfo>> {
  const out = new Map<string, SenderInfo>();
  const distinct = new Map<string, string>(); // nameKey -> display name (first seen)

  for (const n of names) {
    if (isUnreliableSender(n)) {
      const k = nameKey(n); // may be "" — all unreliable senders collapse safely
      if (!out.has(k)) {
        out.set(k, {
          status: "unreliable_sender",
          studentId: null,
          candidateIds: [],
          reason:
            "Sender name is missing or unusable (WhatsApp gave no identity) — please review.",
        });
      }
      continue;
    }
    const key = nameKey(n);
    if (key === "") {
      // Normalized to nothing but not flagged above (e.g. honorifics only).
      if (!out.has(key)) {
        out.set(key, {
          status: "unreliable_sender",
          studentId: null,
          candidateIds: [],
          reason: "Sender name has no usable text — please review.",
        });
      }
      continue;
    }
    if (!distinct.has(key)) distinct.set(key, n.trim());
  }
  if (distinct.size === 0) return out;

  const { data: students } = await supabase
    .from("students")
    .select("id, name, phone, status, active")
    .eq("owner_id", ownerId);

  const activeByName = new Map<string, string[]>();
  const activeByPhone = new Map<string, string[]>();
  const anyByName = new Map<string, string[]>(); // any status (create-guard)
  const activeIds = new Set<string>();

  for (const s of students ?? []) {
    const id = s.id as string;
    if (!id) continue;
    const nk = nameKey((s.name as string) ?? "");
    if (nk) pushId(anyByName, nk, id);
    if (!isActiveStudent(s)) continue;
    activeIds.add(id);
    if (nk) pushId(activeByName, nk, id);
    const pk = phoneKey((s.phone as string) ?? "");
    if (pk) pushId(activeByPhone, pk, id);
  }

  // Aliases let alternate spellings resolve to the same student.
  const { data: aliases } = await supabase
    .from("student_aliases")
    .select("student_id, normalized_alias")
    .eq("owner_id", ownerId);
  const activeByAlias = new Map<string, string[]>();
  const anyAlias = new Set<string>(); // any status (create-guard)
  for (const a of aliases ?? []) {
    const ak = (a.normalized_alias as string) ?? "";
    const sid = a.student_id as string;
    if (!ak || !sid) continue;
    anyAlias.add(ak);
    if (activeIds.has(sid)) pushId(activeByAlias, ak, sid);
  }

  const ambiguousReason = (count: number, display: string) =>
    `${count} active customers saved as “${display}” — left unlinked; choose the right one in review.`;

  // Pool of active customers (by name + alias) for fuzzy suggestions only.
  const fuzzyPool: Array<{ key: string; ids: string[] }> = [];
  for (const [k, ids] of activeByName) fuzzyPool.push({ key: k, ids });
  for (const [k, ids] of activeByAlias) fuzzyPool.push({ key: k, ids });

  for (const [key, display] of distinct.entries()) {
    // 1. Phone — only when the sender is phone-shaped.
    const pk = phoneKey(display);
    if (pk) {
      const ph = activeByPhone.get(pk);
      if (ph && ph.length === 1) {
        out.set(key, { status: "linked", studentId: ph[0], candidateIds: [], reason: "Linked by phone number." });
      } else if (ph && ph.length > 1) {
        out.set(key, { status: "ambiguous", studentId: null, candidateIds: ph.slice(), reason: `${ph.length} active customers share this phone number — choose the right one in review.` });
      } else {
        // Phone number that matches nobody: never invent a customer named after
        // a number; surface it for manual review instead.
        out.set(key, { status: "needs_review", studentId: null, candidateIds: [], reason: "Phone number didn’t match any active customer — please review." });
      }
      continue;
    }

    // 2. Alias — exactly one active student.
    const al = activeByAlias.get(key);
    if (al && al.length === 1) {
      out.set(key, { status: "linked", studentId: al[0], candidateIds: [], reason: "Linked by a saved alias." });
      continue;
    }
    if (al && al.length > 1) {
      out.set(key, { status: "ambiguous", studentId: null, candidateIds: al.slice(), reason: ambiguousReason(al.length, display) });
      continue;
    }

    // 3. Unique normalized name — exactly one active student.
    const nm = activeByName.get(key);
    if (nm && nm.length === 1) {
      out.set(key, { status: "linked", studentId: nm[0], candidateIds: [], reason: "Linked by a unique matching customer name." });
      continue;
    }
    // 4. >1 active customer share the name (the duplicate "Rahul" case).
    if (nm && nm.length > 1) {
      out.set(key, { status: "ambiguous", studentId: null, candidateIds: nm.slice(), reason: ambiguousReason(nm.length, display) });
      continue;
    }

    // 5. No exact active match. We NEVER auto-create a customer from a chat
    //    sender name — spelling variations ("Ashirvad" vs "Ashirwad") would
    //    silently spawn a duplicate of a real student. Mark needs_review and
    //    attach FUZZY SUGGESTIONS only; the owner links manually in review.
    const candidates = fuzzyCandidateIds(key, fuzzyPool);
    // An inactive/paused customer with this exact name is also a strong hint.
    for (const id of anyByName.get(key) ?? []) {
      if (!candidates.includes(id)) candidates.push(id);
    }
    out.set(key, {
      status: "needs_review",
      studentId: null,
      candidateIds: candidates.slice(0, 6),
      reason: candidates.length > 0
        ? "No exact match — showing similar customers to review."
        : "No matching customer found — please review.",
    });
  }

  return out;
}

// Fuzzy suggestions for review ONLY (never used to auto-link). Suggests an
// active customer when the normalized sender shares a meaningful name token, or
// is within a small edit distance (catches single-letter spelling variants like
// "Ashirvad" vs "Ashirwad"). Returns de-duplicated student ids.
function fuzzyCandidateIds(
  key: string,
  pool: Array<{ key: string; ids: string[] }>,
): string[] {
  const keyTokens = new Set(key.split(" ").filter((t) => t !== ""));
  const out: string[] = [];
  for (const cand of pool) {
    if (cand.key === key) continue; // exact match is handled before this step
    let similar = false;
    for (const t of cand.key.split(" ")) {
      if (t.length >= 3 && keyTokens.has(t)) { similar = true; break; }
    }
    if (!similar) {
      const d = levenshtein(key, cand.key);
      const maxLen = Math.max(key.length, cand.key.length);
      if (maxLen > 0 && d <= 2 && d / maxLen <= 0.34) similar = true;
    }
    if (similar) {
      for (const id of cand.ids) if (!out.includes(id)) out.push(id);
    }
  }
  return out;
}

// Standard iterative Levenshtein edit distance.
function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  let prev = Array.from({ length: b.length + 1 }, (_, i) => i);
  let curr = new Array<number>(b.length + 1);
  for (let i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      curr[j] = Math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost);
    }
    [prev, curr] = [curr, prev];
  }
  return prev[b.length];
}

// ---------------------------------------------------------------------------
// Duplicate detection
// ---------------------------------------------------------------------------
// Duplicate identity keys. `sid|`- and `msg|`-prefixed keys share one map but
// can never collide, so a linked request and an unlinked request are always
// compared on the appropriate (different) evidence.

// Strong, confident identity: the request is linked to a real customer. Two
// people who merely share a name have different student_ids and never collide,
// while the same customer re-sending the same meal/action/date is caught.
function linkedDupKey(studentId: string, r: ExtractedRequest): string {
  const dateKey = r.requestDate ?? r.dateLabel ?? "";
  return ["sid", studentId, r.requestType, r.mealType, dateKey].join("|");
}

// Conservative identity for unlinked / ambiguous requests: requires the EXACT
// same original message from the same sender (plus action/meal/date). Two
// different unlinked "Amit"s with different messages hash differently and are
// NOT treated as duplicates; only a re-import of the same message matches.
function unlinkedDupKey(senderKey: string, r: ExtractedRequest): string {
  const dateKey = r.requestDate ?? r.dateLabel ?? "";
  const msgNorm = (r.originalMessage ?? "").toLowerCase().replace(/\s+/g, " ").trim();
  const msgHash = simpleHash(msgNorm);
  return ["msg", senderKey, r.requestType, r.mealType, dateKey, msgHash].join("|");
}

async function loadExistingDupKeys(
  supabase: SupabaseClient,
  ownerId: string,
): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  const { data } = await supabase
    .from("meal_requests")
    .select("id, student_id, student_name, original_message, request_type, meal_type, request_date, date_label")
    .eq("owner_id", ownerId)
    .in("status", ["pending", "approved"])
    .order("created_at", { ascending: false })
    .limit(1000);
  for (const row of data ?? []) {
    const r: ExtractedRequest = {
      studentName: "",
      originalMessage: (row.original_message as string) ?? "",
      requestType: (row.request_type as string) ?? "unclear",
      mealType: (row.meal_type as string) ?? "none",
      dateLabel: (row.date_label as string) ?? "",
      requestDate: (row.request_date as string) ?? null,
      confidence: 0,
      reason: "",
    };
    // Build the same student-aware key the new rows use: linked existing rows
    // key on student_id, unlinked existing rows key on sender + exact message.
    const sid = (row.student_id as string) ?? null;
    const key = sid
      ? linkedDupKey(sid, r)
      : unlinkedDupKey(nameKey((row.student_name as string) ?? ""), r);
    if (!map.has(key)) map.set(key, row.id as string); // newest wins
  }
  return map;
}

// ---------------------------------------------------------------------------
// Gemini
// ---------------------------------------------------------------------------
async function extractWithGemini(
  apiKey: string,
  model: string,
  chatText: string,
  today: string,
): Promise<ExtractedRequest[]> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;

  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      contents: [{ role: "user", parts: [{ text: buildPrompt(chatText, today) }] }],
      generationConfig: {
        temperature: 0.1,
        responseMimeType: "application/json",
      },
    }),
  });

  if (!res.ok) {
    throw new Error(`Gemini HTTP ${res.status}`);
  }
  const data = await res.json();
  const text: string | undefined =
    data?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error("Empty Gemini response");

  const parsed = JSON.parse(stripToJson(text));
  const arr = Array.isArray(parsed) ? parsed : parsed?.requests;
  if (!Array.isArray(arr)) throw new Error("Unexpected Gemini JSON shape");

  return arr
    .map((r) => normalizeRequest(r, today))
    .filter((r): r is ExtractedRequest => r !== null);
}

function buildPrompt(chatText: string, today: string): string {
  return `You extract structured mess (canteen/tiffin) requests from a WhatsApp
group chat for an Indian "Kota mess" owner. Students message in mixed
Hinglish / Hindi / English. Today's date is ${today} (ISO, Asia/Kolkata).

Return ONLY a JSON object of this exact shape:
{
  "requests": [
    {
      "studentName": string,        // sender's name; never invent one
      "originalMessage": string,    // the message text, preserved
      "requestType": one of [${REQUEST_TYPES.map((t) => `"${t}"`).join(", ")}],
      "mealType": one of [${MEAL_TYPES.map((t) => `"${t}"`).join(", ")}],
      "dateLabel": string,          // e.g. "today","tomorrow","Sunday","unspecified"
      "requestDate": "YYYY-MM-DD" | null,
      "confidence": number,         // 0..1
      "reason": string              // short why
    }
  ],
  "warnings": []
}

Request type guidance:
- cancel_meal: skip a specific meal ("kal lunch nahi chahiye").
- add_meal: extra/added meal ("Sunday lunch add kar dena").
- both_meals_cancel: cancel both meals for a day ("aaj dono meal cancel").
- pause_mess: stop mess for a period ("kal se mess band", "2 din ke liye band").
- resume_mess: restart mess ("monday se start kar dena").
- dues_query: asking balance/dues ("kitna due hai?").
- payment_note: says they paid ("payment bhej diya").
- generic_note: relevant but none of the above.
- unclear: mess-related but ambiguous (low confidence).

Rules:
- Do NOT invent student names; use the chat sender's name.
- Preserve the original message text exactly in originalMessage.
- If the date is unclear, set requestDate to null and dateLabel to "unspecified".
- Resolve "aaj"/"today" to ${today}; "kal"/"tomorrow" to the next day; weekday
  names to the next occurrence of that weekday.
- confidence is 0..1; use low confidence for ambiguous messages.
- If a message has no timestamp/date context, lean toward lower confidence when
  the timing is what makes it actionable.
- Return ONLY actionable/relevant requests. Ignore greetings, emoji-only lines,
  "<Media omitted>", deleted messages, links, and unrelated chatter.

WhatsApp chat:
"""
${chatText.slice(0, 20000)}
"""`;
}

function stripToJson(text: string): string {
  let t = text.trim();
  if (t.startsWith("```")) {
    t = t.replace(/^```(json)?/i, "").replace(/```$/i, "").trim();
  }
  const first = t.indexOf("{");
  const firstArr = t.indexOf("[");
  const start =
    first === -1 ? firstArr : firstArr === -1 ? first : Math.min(first, firstArr);
  if (start > 0) t = t.slice(start);
  return t;
}

function normalizeRequest(r: any, today: string): ExtractedRequest | null {
  if (!r || typeof r !== "object") return null;
  const originalMessage = String(r.originalMessage ?? r.original_message ?? "").trim();
  if (originalMessage === "") return null;

  let requestType = String(r.requestType ?? r.request_type ?? "unclear");
  if (!REQUEST_TYPES.includes(requestType)) requestType = "unclear";

  let mealType = String(r.mealType ?? r.meal_type ?? "none");
  if (!MEAL_TYPES.includes(mealType)) mealType = "none";

  let confidence = Number(r.confidence);
  if (!isFinite(confidence)) confidence = 0.5;
  confidence = Math.max(0, Math.min(1, confidence));

  const dateLabel = String(r.dateLabel ?? r.date_label ?? "unspecified").trim() ||
    "unspecified";
  let requestDate: string | null = null;
  const rawDate = r.requestDate ?? r.request_date;
  if (typeof rawDate === "string" && /^\d{4}-\d{2}-\d{2}$/.test(rawDate)) {
    requestDate = rawDate;
  } else {
    requestDate = resolveDate(dateLabel, today);
  }

  return {
    studentName: String(r.studentName ?? r.student_name ?? "Unknown").trim() ||
      "Unknown",
    originalMessage,
    requestType,
    mealType,
    dateLabel,
    requestDate,
    confidence,
    reason: String(r.reason ?? "").trim(),
  };
}

// ---------------------------------------------------------------------------
// WhatsApp parsing
// ---------------------------------------------------------------------------
interface ChatMessage {
  sender: string;
  dateText: string;
  text: string;
}

function parseWhatsApp(raw: string): ChatMessage[] {
  const lines = raw
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .split("\n");

  const messages: ChatMessage[] = [];
  let current: ChatMessage | null = null;

  const push = () => {
    if (current && current.text.trim() !== "") messages.push(current);
  };

  for (const rawLine of lines) {
    const line = rawLine.trim();
    if (line === "") continue;
    const parsed = parseLine(line);
    if (parsed) {
      push();
      current = parsed;
    } else if (current) {
      current.text += " " + line;
    } else {
      // Header-less line: treat as an anonymous message.
      current = { sender: "Unknown", dateText: "", text: line };
    }
  }
  push();
  return messages;
}

function parseLine(line: string): ChatMessage | null {
  // [12/06/26, 8:32:11 PM] Amit: dinner cancel kar do
  let m = line.match(/^\[(.{6,28}?)\]\s*([^:]{1,60}?):\s*(.+)$/);
  if (m) return { dateText: m[1].trim(), sender: m[2].trim(), text: m[3].trim() };

  // 12/06/26, 8:32 pm - Ravi: kal lunch nahi chahiye
  m = line.match(/^(.{6,28}?)\s*-\s*([^:]{1,60}?):\s*(.+)$/);
  if (m) return { dateText: m[1].trim(), sender: m[2].trim(), text: m[3].trim() };

  // Amit - kal se lunch band karna   (sender - message, no time)
  m = line.match(/^([A-Za-z][\w .]{1,40}?)\s*-\s*(.+)$/);
  if (m && !/\d/.test(m[1])) {
    return { dateText: "", sender: m[1].trim(), text: m[2].trim() };
  }

  // Ravi: kal dinner cancel
  m = line.match(/^([A-Za-z][\w .]{1,40}?):\s*(.+)$/);
  if (m) return { dateText: "", sender: m[1].trim(), text: m[2].trim() };

  return null;
}

// Parse a WhatsApp header date/time into a Date (UTC), tolerant of formats.
// Indian exports are day-first: 12/06/26 or 12/06/2026, with 12h or 24h time.
// Returns null when there is no usable timestamp.
function parseTimestamp(dateText: string): Date | null {
  if (!dateText || dateText.trim() === "") return null;
  const cleaned = dateText.replace(/[‎‏]/g, "").trim();

  const dm = cleaned.match(/(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})/);
  if (!dm) return null;
  let day = parseInt(dm[1], 10);
  let month = parseInt(dm[2], 10);
  let year = parseInt(dm[3], 10);
  if (year < 100) year += 2000;
  // If clearly month-first (day field > 12 but month field <= 12 is the common
  // case already handled); swap only when the first field can't be a month.
  if (month > 12 && day <= 12) {
    const t = month;
    month = day;
    day = t;
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;

  let hour = 0;
  let minute = 0;
  let second = 0;
  const tm = cleaned.match(/(\d{1,2}):(\d{2})(?::(\d{2}))?\s*([ap])\.?m?\.?/i);
  if (tm) {
    hour = parseInt(tm[1], 10) % 12;
    minute = parseInt(tm[2], 10);
    second = tm[3] ? parseInt(tm[3], 10) : 0;
    if (/p/i.test(tm[4])) hour += 12;
  } else {
    const t24 = cleaned.match(/(\d{1,2}):(\d{2})(?::(\d{2}))?/);
    if (t24) {
      hour = parseInt(t24[1], 10);
      minute = parseInt(t24[2], 10);
      second = t24[3] ? parseInt(t24[3], 10) : 0;
    }
  }
  const ms = Date.UTC(year, month - 1, day, hour, minute, second);
  if (isNaN(ms)) return null;
  return new Date(ms);
}

// ---------------------------------------------------------------------------
// Late-request cutoff
// ---------------------------------------------------------------------------
// Students must send change/cancel/add requests at least
// `request_cutoff_minutes` before the affected meal. Anything later is FLAGGED
// (is_late_request = true) for owner review — never auto-rejected.
//
// Timezone handling is deliberately library-free and deterministic: WhatsApp
// timestamps are parsed as wall-clock (Asia/Kolkata) via parseTimestamp's
// Date.UTC convention, and the meal time is applied to request_date the same
// way. Both sides use the identical convention, so the comparison is correct
// without any tz conversion.

interface MealTime {
  h: number;
  m: number;
}

interface CutoffSettings {
  breakfast: MealTime | null;
  lunch: MealTime | null;
  dinner: MealTime | null;
  cutoffMinutes: number;
}

interface LateInfo {
  isLate: boolean;
  cutoffAt: string | null; // ISO; the computed deadline (null when not computed)
  messageReceivedAt: string | null; // ISO; when the message arrived (if known)
  lateReason: string | null; // human-readable; only set when late
}

// Parse a Postgres `time` value ("HH:MM" / "HH:MM:SS") into {h, m}. Returns
// null for anything unusable so a blank/missing meal time simply disables the
// check for that meal.
function parseTimeOfDay(value: unknown): MealTime | null {
  if (typeof value !== "string") return null;
  const m = value.trim().match(/^(\d{1,2}):(\d{2})/);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  const min = parseInt(m[2], 10);
  if (h < 0 || h > 23 || min < 0 || min > 59) return null;
  return { h, m: min };
}

// Read the owner's meal times + cutoff window from owner_profiles
// (id == auth uid). Any failure falls back to "no meal times + default
// cutoff", which makes computeLate a no-op rather than crashing the import.
async function loadCutoffSettings(
  supabase: SupabaseClient,
  ownerId: string,
): Promise<CutoffSettings> {
  const fallback: CutoffSettings = {
    breakfast: null,
    lunch: null,
    dinner: null,
    cutoffMinutes: DEFAULT_CUTOFF_MINUTES,
  };
  try {
    const { data } = await supabase
      .from("owner_profiles")
      .select("breakfast_time, lunch_time, dinner_time, request_cutoff_minutes")
      .eq("id", ownerId)
      .maybeSingle();
    if (!data) return fallback;
    const cm = Number(data.request_cutoff_minutes);
    return {
      breakfast: parseTimeOfDay(data.breakfast_time),
      lunch: parseTimeOfDay(data.lunch_time),
      dinner: parseTimeOfDay(data.dinner_time),
      cutoffMinutes: Number.isFinite(cm) && cm >= 0 ? cm : DEFAULT_CUTOFF_MINUTES,
    };
  } catch (_e) {
    return fallback;
  }
}

// Which meal's serving time governs a request, plus a label for the reason.
// "both" binds on the earlier meal (lunch): missing the lunch deadline already
// makes the day's cancellation late. Returns null when no meal time applies
// (meal_type "none"/unknown, or that meal's time isn't configured) — those
// requests are never flagged.
function bindingMeal(
  mealType: string,
  s: CutoffSettings,
): { time: MealTime; label: string } | null {
  switch (mealType) {
    case "breakfast":
      return s.breakfast ? { time: s.breakfast, label: "breakfast" } : null;
    case "lunch":
      return s.lunch ? { time: s.lunch, label: "lunch" } : null;
    case "dinner":
      return s.dinner ? { time: s.dinner, label: "dinner" } : null;
    case "both":
      return s.lunch ? { time: s.lunch, label: "lunch" } : null;
    default:
      return null;
  }
}

// Compute the late-request fields for one request. Missing meal type, missing
// request date, missing message timestamp, or an unconfigured meal time all
// resolve to "not late" — deterministic and crash-free.
function computeLate(
  mealType: string,
  requestDate: string | null,
  messageTs: Date | null,
  s: CutoffSettings,
): LateInfo {
  const notLate: LateInfo = {
    isLate: false,
    cutoffAt: null,
    messageReceivedAt: messageTs ? messageTs.toISOString() : null,
    lateReason: null,
  };
  if (!messageTs) return notLate; // no message timestamp -> never late
  if (!requestDate || !/^\d{4}-\d{2}-\d{2}$/.test(requestDate)) return notLate; // no date
  const meal = bindingMeal(mealType, s);
  if (!meal) return notLate; // no meal type, or that meal's time isn't set

  const [y, mo, d] = requestDate.split("-").map((n) => parseInt(n, 10));
  const mealMs = Date.UTC(y, mo - 1, d, meal.time.h, meal.time.m, 0);
  if (isNaN(mealMs)) return notLate;
  const cutoffMs = mealMs - s.cutoffMinutes * 60_000;
  const isLate = messageTs.getTime() > cutoffMs;

  return {
    isLate,
    cutoffAt: new Date(cutoffMs).toISOString(),
    messageReceivedAt: messageTs.toISOString(),
    lateReason: isLate
      ? `Late request: message was sent after the ${s.cutoffMinutes}-minute cutoff for ${meal.label}.`
      : null,
  };
}

// ---------------------------------------------------------------------------
// Rule-based fallback parser
// ---------------------------------------------------------------------------
function fallbackExtract(messages: ChatMessage[], today: string): ExtractedRequest[] {
  const out: ExtractedRequest[] = [];
  for (const msg of messages) {
    const req = classify(msg, today);
    if (req) out.push(req);
  }
  return out;
}

function classify(msg: ChatMessage, today: string): ExtractedRequest | null {
  const text = msg.text.trim();
  const lower = normalize(text);
  if (isNoise(lower)) return null;

  const has = (terms: string[]) => terms.some((t) => lower.includes(t));

  const mealType = detectMeal(lower);
  const dateLabel = detectDateLabel(lower, msg.dateText);
  const requestDate = resolveDate(dateLabel, today);

  let requestType: string | null = null;
  let confidence = 0.55;

  const cancelWords = has([
    "cancel", "nahi chahiye", "nhi chahiye", "nahin chahiye", "mat banana",
    "mat bhejna", "skip", "nahi banana", "no lunch", "no dinner", "band karo",
  ]);
  const bothWords = has(["dono", "both", "donon"]);

  if (has(["paid", "payment", "bhej diya", "de diya", "pay kar", "transfer", "upi", "gpay", "phonepe", "paytm"])) {
    requestType = "payment_note";
    confidence = 0.7;
  } else if (has(["kitna due", "kitna baki", "due kitna", "balance", "kitna hua", "kitne ka", "due hai", "bill kitna", "hisab"])) {
    requestType = "dues_query";
    confidence = 0.7;
  } else if (has(["resume", "restart", "start kar", "chalu", "shuru", "continue"])) {
    requestType = "resume_mess";
    confidence = 0.72;
  } else if (has(["mess band", "band kar", "bandh", "chhutti", "ghar ja", "out of station", "pause", "din ke liye band", "din band"])) {
    requestType = "pause_mess";
    confidence = 0.68;
  } else if (bothWords && cancelWords) {
    requestType = "both_meals_cancel";
    confidence = 0.7;
  } else if (has(["add", "extra", "aur ek", "ek aur", "badha", "zyada", "one more", "extra plate"])) {
    requestType = "add_meal";
    confidence = 0.66;
  } else if (cancelWords) {
    requestType = "cancel_meal";
    confidence = 0.7;
  } else if (looksMessRelated(lower)) {
    requestType = "unclear";
    confidence = 0.3;
  } else {
    return null;
  }

  if (mealType === "none" &&
      (requestType === "cancel_meal" || requestType === "add_meal")) {
    confidence -= 0.1;
  }
  // No timestamp context lowers certainty for timing-dependent requests.
  if (msg.dateText === "" && dateLabel === "unspecified" &&
      (requestType === "cancel_meal" || requestType === "add_meal" ||
       requestType === "both_meals_cancel")) {
    confidence -= 0.1;
  }

  return {
    studentName: cleanSender(msg.sender),
    originalMessage: text,
    requestType,
    mealType: requestType === "both_meals_cancel" ? "both" : mealType,
    dateLabel,
    requestDate,
    confidence: Math.max(0, Math.min(1, confidence)),
    reason: "Matched by rule-based fallback parser.",
  };
}

function detectMeal(lower: string): string {
  const lunch = /(lunch|dopahar|afternoon|din ka khana)/.test(lower);
  const dinner = /(dinner|raat|night|sham)/.test(lower);
  if (lunch && dinner) return "both";
  if (lunch) return "lunch";
  if (dinner) return "dinner";
  if (/(dono|both)/.test(lower)) return "both";
  return "none";
}

function detectDateLabel(lower: string, _fallback: string): string {
  if (/(aaj|today)/.test(lower)) return "today";
  if (/(kal|tomorrow|tmrw)/.test(lower)) return "tomorrow";
  const days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
  for (const d of days) {
    if (lower.includes(d)) return d.charAt(0).toUpperCase() + d.slice(1);
  }
  return "unspecified";
}

function resolveDate(dateLabel: string, today: string): string | null {
  const base = new Date(today + "T00:00:00Z");
  if (isNaN(base.getTime())) return null;
  const label = dateLabel.toLowerCase();
  if (label === "today") return today;
  if (label === "tomorrow") {
    base.setUTCDate(base.getUTCDate() + 1);
    return base.toISOString().slice(0, 10);
  }
  const days = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
  const idx = days.indexOf(label);
  if (idx !== -1) {
    let diff = (idx - base.getUTCDay() + 7) % 7;
    if (diff === 0) diff = 7; // next occurrence, not today
    base.setUTCDate(base.getUTCDate() + diff);
    return base.toISOString().slice(0, 10);
  }
  return null;
}

function isNoise(lower: string): boolean {
  if (lower === "") return true;
  if (lower.length < 2) return true;
  if (lower.includes("media omitted") || lower.includes("image omitted") ||
      lower.includes("video omitted") || lower.includes("sticker omitted") ||
      lower.includes("audio omitted") || lower.includes("document omitted") ||
      lower.includes("this message was deleted") ||
      lower.includes("messages and calls are end-to-end encrypted") ||
      lower.includes("missed voice call") || lower.includes("missed video call")) {
    return true;
  }
  // greetings / pure pleasantries only
  if (/^(hi|hello|hey|gm|good morning|good night|gn|ok|okay|thanks|thank you|theek hai|thik hai|ji|haan|hmm+)\.?$/.test(lower)) {
    return true;
  }
  return false;
}

function looksMessRelated(lower: string): boolean {
  return /(khana|meal|lunch|dinner|tiffin|dabba|mess|roti|rice|sabzi|plate|khane)/.test(lower);
}

function normalize(value: string): string {
  return value
    .toLowerCase()
    .replace(/₹/g, " rs ")
    .replace(/[^a-z0-9\s]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function cleanSender(value: string): string {
  const clean = value.replace(/\+?91[\s-]*/g, "").replace(/[~‪-‮]/g, "").trim();
  return clean === "" ? "Unknown" : clean;
}

// Small deterministic hash (djb2) -> hex. Used for import / message hashes.
function simpleHash(input: string): string {
  let h = 5381;
  for (let i = 0; i < input.length; i++) {
    h = ((h << 5) + h + input.charCodeAt(i)) >>> 0;
  }
  return h.toString(16);
}
