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
// full_day, …) are NOT used — the live DB CHECK constraints enforce
// the existing app vocabulary (cancel_meal/add_meal/…, lunch/dinner/both/none,
// status pending/approved/rejected/completed/cancelled). We keep the existing
// vocabulary so inserts pass and the Requests review flow keeps working.
//
// Deploy:  supabase functions deploy extract-requests
// Secrets: supabase secrets set GEMINI_API_KEY=...
//          supabase secrets set GEMINI_MODEL=gemini-2.5-flash   (optional)

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { isGroupSystemLine, parseRosterEvents } from "./roster_parser.ts";
import { messageFingerprint, parseTimestamp } from "./fingerprint.ts";
import { clampDelta, deltasFor, detectQuantity } from "./quantity.ts";
import {
  detectDurationDays,
  resolveMealDateFromText,
  resolveMealDateRangeFromText,
} from "./dates.ts";

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

// Long-import safety. Candidate (likely-actionable) messages are sent to Gemini
// in batches so one big export never becomes one giant, slow request, and a
// per-batch timeout keeps the whole import from hanging indefinitely. If a
// single batch fails (or times out), only that batch falls back to the
// rule-based parser — the rest of the import still uses Gemini.
const GEMINI_BATCH_SIZE = 50;
const GEMINI_TIMEOUT_MS = 40_000;

// Lightweight phase timing for the Edge Function logs. Logs COUNTS and DURATIONS
// only — never raw chat text, never student names, never the Gemini key.
function logTiming(phase: string, ms: number, extra: Record<string, unknown> = {}): void {
  console.log("[extract-requests] timing", JSON.stringify({ phase, ms, ...extra }));
}

interface ExtractedRequest {
  studentName: string;
  originalMessage: string;
  requestType: string;
  mealType: string;
  // Signed per-meal quantity change. +N adds N, -N removes/cancels N, 0 = no
  // change. e.g. "kal do lunch extra dena" -> lunchDelta +2, dinnerDelta 0.
  lunchDelta: number;
  dinnerDelta: number;
  dateLabel: string;
  requestDate: string | null;
  // Inclusive end date for a multi-day pause/cancel ("kal se ek hafte tak").
  // null = single-day request (treat as requestDate). The per-meal deltas apply
  // to every day in [requestDate, requestEndDate].
  requestEndDate: string | null;
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
  // Roster onboarding from group join/add system messages (e.g.
  // "Rahul Room 204 joined using a group link."). Independent of meal requests.
  rosterFound: number; // distinct join/add names seen in this import
  rosterCreated: number; // new customers created from join events
  rosterMatched: number; // join names that already mapped to one customer
  rosterAmbiguous: number; // join names that matched >1 customer (left for review)
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
    rosterFound: 0,
    rosterCreated: 0,
    rosterMatched: 0,
    rosterAmbiguous: 0,
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
  const t0 = Date.now();
  try {
    // --- Roster onboarding from group join/add system messages ----------
    // Parsed from the WHOLE export (not the 90-day window) since onboarding a
    // student is not time-sensitive. Runs BEFORE meal-request resolution so a
    // "Rahul Room 204: No dinner today" later in the same import links to the
    // customer this step just created/matched. Priya creates a dedicated group
    // for CURRENT active mess students, so everyone who joins/was added is an
    // active customer — onboardRoster bulk-creates them (see onboardRoster).
    const tRoster = Date.now();
    const rosterEvents = parseRosterEvents(chatText);
    const roster = await onboardRoster(supabase, ownerId, rosterEvents, warnings);
    logTiming("roster", Date.now() - tRoster, {
      found: roster.found,
      matched: roster.matched,
      created: roster.created,
      ambiguous: roster.ambiguous,
    });

    // --- Parse + 90-day window -----------------------------------------
    const tParse = Date.now();
    const parsed = parseWhatsApp(chatText);
    logTiming("parse_whatsapp", Date.now() - tParse, { count: parsed.length });
    const cutoffMs = Date.parse(today + "T00:00:00Z") - RETENTION_DAYS * 86_400_000;

    const inWindow: ChatMessage[] = [];
    let skippedOld = 0;
    for (const m of parsed) {
      const ts = parseTimestamp(m.dateText);
      if (ts && ts.getTime() < cutoffMs) {
        skippedOld++; // old message with a real timestamp — outside the window
        continue;
      }
      inWindow.push(m);
    }

    // --- Idempotency: skip already-imported messages by fingerprint -----
    // Re-importing the SAME WhatsApp export (e.g. Priya uploads the full chat
    // again) must NOT recreate requests the owner already accepted/rejected.
    // We fingerprint every in-window message (owner + normalized sender +
    // timestamp + text — robust to re-export whitespace/am-pm quirks), batch-
    // check which fingerprints this owner has already seen, and DROP the known
    // ones BEFORE Gemini/fallback extraction so old messages neither recreate
    // requests nor cost extraction. This is independent of request status — a
    // re-imported message is skipped whether its request was approved, rejected
    // or still pending. The fingerprint registry rows are written at the END,
    // only after the requests are created (see whatsapp_message_fingerprints),
    // so a mid-import failure never silently swallows a message on retry.
    const tFp = Date.now();
    const inWindowFps = await Promise.all(
      inWindow.map((m) => messageFingerprint(ownerId, cleanSender(m.sender), m.dateText, m.text)),
    );
    // Collapse messages that are identical within THIS export (first wins), so a
    // single import never tries to register the same fingerprint twice.
    const seenInBatch = new Set<string>();
    const distinctMessages: ChatMessage[] = [];
    const distinctFps: string[] = [];
    for (let i = 0; i < inWindow.length; i++) {
      const fp = inWindowFps[i];
      if (seenInBatch.has(fp)) continue;
      seenInBatch.add(fp);
      distinctMessages.push(inWindow[i]);
      distinctFps.push(fp);
    }
    const knownFps = await loadExistingFingerprints(supabase, ownerId, distinctFps);
    const processed: ChatMessage[] = [];
    const processedFps: string[] = [];
    for (let i = 0; i < distinctMessages.length; i++) {
      if (knownFps.has(distinctFps[i])) continue; // already imported before — skip
      processed.push(distinctMessages[i]);
      processedFps.push(distinctFps[i]);
    }
    logTiming("fingerprint_dedup", Date.now() - tFp, {
      inWindow: inWindow.length,
      distinct: distinctMessages.length,
      fresh: processed.length,
      skippedDuplicates: inWindow.length - processed.length,
    });

    const totalMessages = parsed.length;
    const processedMessages = processed.length;

    // --- Persist the processed messages --------------------------------
    // text_message -> id, used later to link meal_requests.message_id.
    const messageIdByText = new Map<string, string>();
    // text_message -> parsed receipt time, used for the late-request cutoff
    // check below. First occurrence wins (mirrors messageIdByText).
    const messageTsByText = new Map<string, Date>();
    if (processed.length > 0) {
      const tMsg = Date.now();
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
      logTiming("chat_messages_insert", Date.now() - tMsg, { count: rows.length });
    }

    // --- Extract (Gemini on candidate messages, batched) ----------------
    // Instead of sending the whole in-window export to Gemini, we first reduce
    // it to the likely-actionable CANDIDATE messages (meal/cancel/payment/…),
    // then send those in batches with a per-batch timeout. This keeps long
    // imports fast and bounded, and lets a single failing batch fall back to
    // the rule-based parser without sinking the whole import.
    const geminiKey = Deno.env.get("GEMINI_API_KEY");
    const geminiModel = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";
    const requests = await extractRequests(
      geminiKey,
      geminiModel,
      processed,
      today,
      warnings,
    );

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
        lunch_delta: r.lunchDelta,
        dinner_delta: r.dinnerDelta,
        request_date: r.requestDate,
        request_end_date: r.requestEndDate,
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
      const tReq = Date.now();
      const { data: insertedReqs, error: reqErr } = await supabase
        .from("meal_requests")
        .insert(rows)
        .select("id");
      if (reqErr) throw reqErr;
      insertedIds = (insertedReqs ?? []).map((r) => r.id as string);
      logTiming("meal_requests_insert", Date.now() - tReq, { count: rows.length });
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

    // --- Register fingerprints for the messages we just imported -------
    // Done LAST, after the requests exist, so a failure earlier in the pipeline
    // never marks a message as "seen" without its request being created (a retry
    // would otherwise skip it forever). Best-effort + ignore-duplicates: the
    // unique (owner_id, message_fingerprint) key makes this safe under a re-run
    // or a concurrent import, and a registry hiccup shouldn't fail an otherwise
    // successful import (the worst case is one message re-offered next import).
    if (processedFps.length > 0) {
      const tReg = Date.now();
      const fpRows = processed.map((m, i) => ({
        owner_id: ownerId,
        message_fingerprint: processedFps[i],
        chat_message_id: messageIdByText.get(m.text) ?? null,
      }));
      try {
        const { error: fpErr } = await supabase
          .from("whatsapp_message_fingerprints")
          .upsert(fpRows, { onConflict: "owner_id,message_fingerprint", ignoreDuplicates: true });
        if (fpErr) throw fpErr;
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        console.error("[extract-requests] fingerprint registry write failed.", JSON.stringify({ count: fpRows.length, error: msg }));
        warnings.push("Could not record import fingerprints; a re-import may re-offer these messages.");
      }
      logTiming("fingerprint_register", Date.now() - tReg, { count: fpRows.length });
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
      rosterFound: roster.found,
      rosterCreated: roster.created,
      rosterMatched: roster.matched,
      rosterAmbiguous: roster.ambiguous,
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

    logTiming("total", Date.now() - t0, {
      processed: processedMessages,
      extracted: insertedIds.length,
    });
    return json({ importId, status: "completed", summary, warnings }, 200);
  } catch (e) {
    // Mark the import failed and return a useful message to the client.
    const message = e instanceof Error ? e.message : "Import failed.";
    logTiming("total_failed", Date.now() - t0, {});
    try {
      await supabase
        .from("chat_imports")
        .update({ status: "failed", error_message: message.slice(0, 500) })
        .eq("id", importId)
        .eq("owner_id", ownerId);
    } catch (_e) {
      // best-effort; nothing more we can do here.
    }
    // A timeout / abort almost always means the export was too big to finish in
    // one import — give the owner an actionable hint instead of a generic error.
    const low = message.toLowerCase();
    const looksTooLarge = low.includes("timeout") || low.includes("timed out") ||
      low.includes("abort") || low.includes("deadline");
    const userError = looksTooLarge
      ? "This WhatsApp export is too large to process in one import. Try a smaller date range or import recent chat only."
      : "Import failed while processing. Please try again.";
    return json(
      { importId, status: "failed", error: userError, summary: emptySummary(), warnings },
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
// Roster onboarding: creating/matching customers from join/add events
// ---------------------------------------------------------------------------
interface RosterResult {
  found: number; // distinct usable join/add names
  created: number; // new customers created
  matched: number; // names that mapped to exactly one existing customer
  ambiguous: number; // names that matched >1 customer (left for review)
}

// CREATE or MATCH a customer for each parsed join/add name. Priya opens a fresh
// WhatsApp group for her CURRENT active mess students, so everyone who joins (or
// was added) is an active customer and should exist in the app. We use the SAME
// conservative matching the meal-request resolver uses (unique phone, unique
// alias, unique name); a name that matches no existing active customer is
// created as a new active customer so a later meal message from that person
// links automatically (normal Approve, not "Resolve first").
//
// Performance: a long export can carry hundreds of join events. We do NOT do one
// INSERT per name (the old hang). Instead we classify every distinct name first
// (matched / ambiguous / to-create), then bulk-insert the new students in one
// round trip and the aliases in a second — at most four DB calls total
// regardless of roster size.
//
// Outcomes per distinct join name:
//   * Maps to exactly one existing customer (phone/alias/name) -> matched.
//   * Maps to >1 active customer -> ambiguous (left for the owner to resolve);
//     never blindly duplicated.
//   * Phone-shaped name (unsaved contact) -> matched only if one phone matches;
//     never spawns a customer named after a number (counted as ambiguous).
//   * No active match -> created as a new active customer.
async function onboardRoster(
  supabase: SupabaseClient,
  ownerId: string,
  rawNames: string[],
  warnings: string[],
): Promise<RosterResult> {
  const result: RosterResult = { found: 0, created: 0, matched: 0, ambiguous: 0 };

  // Dedupe within this import by normalized key; keep the first-seen display.
  // isUnreliableSender drops empty / "Unknown" / symbol-only names, so we never
  // create a customer named "Unknown" or from a symbol-only line.
  const distinct = new Map<string, string>(); // nameKey -> display name
  for (const n of rawNames) {
    if (isUnreliableSender(n)) continue;
    const key = nameKey(n);
    if (key === "") continue;
    if (!distinct.has(key)) distinct.set(key, n.trim());
  }
  if (distinct.size === 0) return result;
  result.found = distinct.size;

  // Snapshot existing customers + aliases ONCE (mirrors resolveSenders).
  const { data: students } = await supabase
    .from("students")
    .select("id, name, phone, status, active")
    .eq("owner_id", ownerId);

  const activeByName = new Map<string, string[]>();
  const activeByPhone = new Map<string, string[]>();
  const activeIds = new Set<string>();
  for (const s of students ?? []) {
    const id = s.id as string;
    if (!id || !isActiveStudent(s)) continue;
    activeIds.add(id);
    const nk = nameKey((s.name as string) ?? "");
    if (nk) pushId(activeByName, nk, id);
    const pk = phoneKey((s.phone as string) ?? "");
    if (pk) pushId(activeByPhone, pk, id);
  }

  const { data: aliases } = await supabase
    .from("student_aliases")
    .select("student_id, normalized_alias")
    .eq("owner_id", ownerId);
  const activeByAlias = new Map<string, string[]>();
  const existingAliasKeys = new Set<string>(); // any-status, for the create-guard
  for (const a of aliases ?? []) {
    const ak = (a.normalized_alias as string) ?? "";
    const sid = a.student_id as string;
    if (!ak || !sid) continue;
    existingAliasKeys.add(ak);
    if (activeIds.has(sid)) pushId(activeByAlias, ak, sid);
  }

  // Collect alias rows to insert in ONE bulk write at the end. seenAliasKeys
  // guards both pre-existing aliases (unique index on owner+normalized_alias)
  // and within-batch duplicates.
  const seenAliasKeys = new Set<string>(existingAliasKeys);
  const aliasRows: Array<{ owner_id: string; student_id: string; alias: string; normalized_alias: string }> = [];
  const queueAlias = (studentId: string, display: string, key: string) => {
    if (key === "" || seenAliasKeys.has(key)) return;
    seenAliasKeys.add(key);
    aliasRows.push({ owner_id: ownerId, student_id: studentId, alias: display, normalized_alias: key });
  };

  // Names with no active match — created in bulk below.
  const toCreate: Array<{ key: string; display: string }> = [];

  for (const [key, display] of distinct.entries()) {
    // Phone-shaped join name (unsaved contact): match by phone only; never
    // create a customer named after a number.
    const pk = phoneKey(display);
    if (pk) {
      const ph = activeByPhone.get(pk) ?? [];
      if (ph.length === 1) result.matched++;
      else result.ambiguous++; // 0 or >1 -> needs owner review, no creation
      continue;
    }

    // 1. Unique saved alias.
    const al = activeByAlias.get(key) ?? [];
    if (al.length === 1) { result.matched++; continue; }
    if (al.length > 1) { result.ambiguous++; continue; }

    // 2. Unique active name.
    const nm = activeByName.get(key) ?? [];
    if (nm.length === 1) {
      // Store the verbatim WhatsApp name as an alias for exact future matching.
      queueAlias(nm[0], display, key);
      result.matched++;
      continue;
    }
    // 3. >1 active customer already share this name — never blindly duplicate;
    //    leave ambiguous for the owner to resolve in review.
    if (nm.length > 1) { result.ambiguous++; continue; }

    // 4. No active match -> create a new active customer. Deferred to the bulk
    //    insert below so a big roster is one round trip, not one INSERT per name.
    toCreate.push({ key, display });
  }

  // --- Bulk-create the new active customers in a single round trip ----------
  if (toCreate.length > 0) {
    try {
      const insertRows = toCreate.map((c) => ({
        owner_id: ownerId,
        name: c.display,
        status: "active",
      }));
      const { data: created, error } = await supabase
        .from("students")
        .insert(insertRows)
        .select("id, name");
      if (error) throw error;
      result.created = created?.length ?? 0;
      // Store each created student's WhatsApp display name as an alias too, so
      // resolveSenders links a later meal message by alias as well as by name.
      for (const row of created ?? []) {
        const id = row.id as string;
        const nm = (row.name as string) ?? "";
        if (id) queueAlias(id, nm, nameKey(nm));
      }
    } catch (e) {
      // Don't fail the whole import over roster creation; report the names as
      // skipped/needs-review and warn. The owner can add them manually.
      const msg = e instanceof Error ? e.message : String(e);
      console.error("[extract-requests] roster bulk create failed.", JSON.stringify({ count: toCreate.length, error: msg }));
      warnings.push("Some new students from group join events could not be created automatically — add them from the Customers screen.");
      result.ambiguous += toCreate.length;
    }
  }

  // --- Bulk-insert the collected aliases (best effort) ----------------------
  if (aliasRows.length > 0) {
    try {
      await supabase.from("student_aliases").insert(aliasRows);
    } catch (_e) {
      // Best effort: exact future matching still works via the unique name.
    }
  }

  return result;
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
      lunchDelta: 0, // not part of the duplicate identity key
      dinnerDelta: 0,
      dateLabel: (row.date_label as string) ?? "",
      requestDate: (row.request_date as string) ?? null,
      requestEndDate: null, // not part of the duplicate identity key
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
// WhatsApp message fingerprints (import idempotency)
// ---------------------------------------------------------------------------
// Which of the supplied fingerprints this owner has already imported. Batched
// in chunks so a big export is a handful of `in (...)` queries, not one per
// message, and so we never blow the PostgREST URL length limit. RLS already
// scopes to the owner; the explicit owner_id filter keeps the index lookup tight.
async function loadExistingFingerprints(
  supabase: SupabaseClient,
  ownerId: string,
  fingerprints: string[],
): Promise<Set<string>> {
  const found = new Set<string>();
  const CHUNK = 200;
  for (let i = 0; i < fingerprints.length; i += CHUNK) {
    const slice = fingerprints.slice(i, i + CHUNK);
    if (slice.length === 0) continue;
    const { data, error } = await supabase
      .from("whatsapp_message_fingerprints")
      .select("message_fingerprint")
      .eq("owner_id", ownerId)
      .in("message_fingerprint", slice);
    if (error) throw error;
    for (const r of data ?? []) found.add(r.message_fingerprint as string);
  }
  return found;
}

// ---------------------------------------------------------------------------
// Candidate filtering + batched Gemini extraction
// ---------------------------------------------------------------------------
// A WhatsApp export is mostly chatter. Sending all of it to Gemini is slow and
// pointless, so we first reduce the in-window messages to CANDIDATES — the ones
// that look like an actual mess request (meal/cancel/pause/payment/dues). Only
// candidates are sent to Gemini, in batches, each with its own timeout.

// A candidate is just a processed ChatMessage that survived the prefilter. Its
// position within its Gemini batch is the stable "#<index>" used in the prompt,
// so the model's output maps back to the exact original message (and its stored
// chat_messages row) even if the model rephrases the text.
type Candidate = ChatMessage;

// Keyword signal for "this message might be an actionable mess request". Kept
// deliberately broad (Hinglish + English) — precision is Gemini's job; this is
// only a cheap prefilter to cut volume. Anything matched here still goes to the
// model (or the fallback parser) for the real decision.
const CANDIDATE_RE =
  /(lunch|dinner|meal|tiffin|dabba|mess|khana|khane|roti|rice|sabzi|plate|cancel|nahi|nahin|nhi|mat banana|mat bhejna|skip|band|bandh|chhutti|chutti|pause|ghar ja|out of station|start|resume|restart|chalu|shuru|continue|payment|paid|pay kar|bhej diya|de diya|transfer|upi|gpay|phonepe|paytm|due|baki|balance|hisab|hisaab|kitna|add|extra|badha|zyada|kam|hata|ghata|remove)/;

function isCandidate(text: string): boolean {
  const lower = normalize(text);
  if (isNoise(lower)) return false;
  return CANDIDATE_RE.test(lower);
}

function buildCandidates(processed: ChatMessage[]): Candidate[] {
  return processed.filter((m) => isCandidate(m.text));
}

// Orchestrate extraction over the candidate messages. Sends Gemini one batch at
// a time (with a per-batch timeout); a batch that fails or times out falls back
// to the rule-based parser for THAT batch only, so the rest of the import still
// benefits from Gemini. Returns the merged requests. Never throws — extraction
// problems degrade to the fallback parser rather than failing the import.
async function extractRequests(
  geminiKey: string | undefined,
  geminiModel: string,
  processed: ChatMessage[],
  today: string,
  warnings: string[],
): Promise<ExtractedRequest[]> {
  const tCand = Date.now();
  const candidates = buildCandidates(processed);
  logTiming("candidates", Date.now() - tCand, {
    processed: processed.length,
    candidates: candidates.length,
  });

  if (candidates.length === 0) return [];

  // No key configured -> straight to the fallback parser for all candidates.
  if (!geminiKey) {
    console.warn("[extract-requests] GEMINI_API_KEY is not set — using fallback parser.");
    warnings.push("GEMINI_API_KEY not set; used fallback parser.");
    return fallbackExtract(candidates, today);
  }

  const batches: Candidate[][] = [];
  for (let i = 0; i < candidates.length; i += GEMINI_BATCH_SIZE) {
    batches.push(candidates.slice(i, i + GEMINI_BATCH_SIZE));
  }

  const out: ExtractedRequest[] = [];
  let failedBatches = 0;
  const tGem = Date.now();
  for (let b = 0; b < batches.length; b++) {
    const batch = batches[b];
    const tBatch = Date.now();
    try {
      const reqs = await extractCandidatesWithGemini(geminiKey, geminiModel, batch, today);
      logTiming("gemini_batch", Date.now() - tBatch, {
        batch: b,
        candidates: batch.length,
        requests: reqs.length,
      });
      out.push(...reqs);
    } catch (e) {
      // Log the REAL failure (safe fields only: no key, no chat text), then fall
      // back for just this batch so other batches keep their Gemini results.
      const errMsg = e instanceof Error ? e.message : String(e);
      console.error(
        "[extract-requests] Gemini batch failed — using fallback parser for this batch.",
        JSON.stringify({
          batch: b,
          geminiKeyPresent: true, // boolean only, never the key
          geminiModel,
          geminiError: errMsg, // includes "Gemini HTTP <status>: …" or "timeout"
          usedFallback: true,
        }),
      );
      logTiming("gemini_batch_failed", Date.now() - tBatch, { batch: b, candidates: batch.length });
      failedBatches++;
      out.push(...fallbackExtract(batch, today));
    }
  }
  logTiming("gemini_total", Date.now() - tGem, {
    batches: batches.length,
    failedBatches,
    requests: out.length,
  });

  if (failedBatches > 0) {
    warnings.push(
      failedBatches === batches.length
        ? "Gemini extraction failed; used fallback parser."
        : "Gemini extraction failed for part of this import; used fallback parser for those messages.",
    );
  }
  return out;
}

// One Gemini batch. Sends only the candidate messages (each with its stable
// index), enforces a timeout via AbortController, and maps each returned request
// back to its source candidate by `messageIndex` so the original sender + text
// are authoritative (the model can rephrase; we don't trust it for identity).
async function extractCandidatesWithGemini(
  apiKey: string,
  model: string,
  batch: Candidate[],
  today: string,
): Promise<ExtractedRequest[]> {
  const url =
    `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${apiKey}`;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GEMINI_TIMEOUT_MS);
  let res: Response;
  try {
    res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: buildPrompt(batch, today) }] }],
        generationConfig: {
          temperature: 0.1,
          responseMimeType: "application/json",
        },
      }),
      signal: controller.signal,
    });
  } catch (e) {
    // AbortError -> surface as a timeout so the caller's user-facing message and
    // the fallback path both kick in. Re-throw anything else as-is.
    if (e instanceof DOMException && e.name === "AbortError") {
      throw new Error(`Gemini request timed out after ${GEMINI_TIMEOUT_MS}ms`);
    }
    throw e;
  } finally {
    clearTimeout(timer);
  }

  if (!res.ok) {
    // Read a short body snippet so the real cause (bad key, wrong model,
    // quota exceeded, …) reaches the logs. The body is Gemini's own error
    // JSON — it never contains our API key (the key is only in the URL, which
    // we do NOT include here). Cap the snippet to keep logs small.
    let snippet = "";
    try {
      snippet = (await res.text()).slice(0, 500).replace(/\s+/g, " ").trim();
    } catch (_e) {
      // body unreadable — status alone still tells us a lot.
    }
    throw new Error(
      snippet ? `Gemini HTTP ${res.status}: ${snippet}` : `Gemini HTTP ${res.status}`,
    );
  }
  const data = await res.json();
  const text: string | undefined =
    data?.candidates?.[0]?.content?.parts?.[0]?.text;
  if (!text) throw new Error("Empty Gemini response");

  const parsed = JSON.parse(stripToJson(text));
  const arr = Array.isArray(parsed) ? parsed : parsed?.requests;
  if (!Array.isArray(arr)) throw new Error("Unexpected Gemini JSON shape");

  const out: ExtractedRequest[] = [];
  for (const raw of arr) {
    // Map back to the source candidate by index when the model returned one.
    // The candidate's sender + verbatim text are authoritative, so message_id
    // linking (which matches on original_message) always succeeds — and its
    // timestamp is the base for resolving relative meal dates (aaj/kal/parso).
    const idxRaw = raw?.messageIndex ?? raw?.message_index ?? raw?.index;
    const idx = Number(idxRaw);
    const src =
      Number.isInteger(idx) && idx >= 0 && idx < batch.length ? batch[idx] : null;
    const messageTs = src ? parseTimestamp(src.dateText) : null;
    const req = normalizeRequest(raw, today, messageTs);
    if (!req) continue;
    if (src) {
      req.studentName = cleanSender(src.sender);
      req.originalMessage = src.text;
    }
    out.push(req);
  }
  return out;
}

function buildPrompt(batch: Candidate[], today: string): string {
  // Pre-filtered candidate messages, one per line. The "#<index>" is the
  // BATCH-LOCAL position (0-based) so it maps straight back via batch[idx] in
  // extractCandidatesWithGemini — each batch is its own Gemini call.
  const lines = batch
    .map((c, i) => `#${i} ${c.dateText ? `[${c.dateText}] ` : ""}${c.sender}: ${c.text}`)
    .join("\n");

  return `You extract structured mess (canteen/tiffin) requests from WhatsApp
messages for an Indian "Kota mess" owner. Students message in mixed
Hinglish / Hindi / English. Today's date is ${today} (ISO, Asia/Kolkata).

The messages below are PRE-FILTERED candidates, each prefixed with "#<index>".

Return ONLY a JSON object of this exact shape:
{
  "requests": [
    {
      "messageIndex": number,       // the #<index> of the source message
      "studentName": string,        // sender's name; never invent one
      "originalMessage": string,    // the message text, preserved
      "requestType": one of [${REQUEST_TYPES.map((t) => `"${t}"`).join(", ")}],
      "mealType": one of [${MEAL_TYPES.map((t) => `"${t}"`).join(", ")}],
      "lunchDelta": number,         // signed change to lunches: +N adds N, -N removes N, 0 = no change
      "dinnerDelta": number,        // signed change to dinners: +N adds N, -N removes N, 0 = no change
      "dateLabel": string,          // e.g. "today","tomorrow","day_after_tomorrow","Sunday","unspecified"
      "requestDate": "YYYY-MM-DD" | null,     // START date of the request
      "requestEndDate": "YYYY-MM-DD" | null,  // END date (inclusive) for a multi-day pause; null if single day
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

Quantity (lunchDelta / dinnerDelta) guidance:
- Requests can change MORE THAN ONE meal. Read the number and the direction.
- Numbers may be digits (1,2,3) or Hindi/Hinglish words: ek/one=1, do/two=2,
  teen/three=3, char/chaar/four=4, paanch/panch/five=5.
- Positive (add) words: extra, add, aur, jyada/zyada, badha, "extra dena".
- Negative (remove) words: cancel, kam, hata, remove, nahi, "mat dena".
- If no explicit number, the quantity is 1.
- In Hinglish "do" before a meal word means the NUMBER 2 (e.g. "do lunch extra",
  "do dinner cancel", "do lunch kam"). "kar do" at the end just means "do it" —
  not a number.
- Examples: "kal do lunch extra dena" -> lunchDelta +2, dinnerDelta 0;
  "aaj 3 dinner extra" -> dinnerDelta +3; "kal 2 lunch kam kar dena" ->
  lunchDelta -2; "do dinner cancel kar dena" -> dinnerDelta -2;
  "lunch dinner cancel" -> lunchDelta -1, dinnerDelta -1.
- For add_meal use positive deltas; for cancel_meal / both_meals_cancel use
  negative deltas; for non-meal types (pause/resume/payment/dues/note/unclear)
  set both deltas to 0.

Rules:
- Always include the source "messageIndex" for every request.
- Do NOT invent student names; use the chat sender's name.
- Preserve the original message text exactly in originalMessage.
- If the date is unclear, set requestDate to null and dateLabel to "unspecified".
- Resolve relative day words against THAT MESSAGE'S timestamp (the [date time]
  shown in brackets before the sender), NOT today's date. Today's date is only
  for messages that carry no timestamp at all.
    * aaj / aj / today      = message date
    * kal / tomorrow        = message date + 1 day
    * parso / parson / day after tomorrow = message date + 2 days
    * a weekday name        = the next occurrence of that weekday after the
                              message date
  (These are operational mess requests, so "kal" always means TOMORROW, never
  yesterday.) An explicit calendar date in the text (e.g. "28 June", "28/06")
  takes priority over a relative word. Output requestDate as "YYYY-MM-DD".
- Date RANGE / multi-day pause: when a duration is given, set requestDate to the
  START day and requestEndDate to the inclusive END day. end = start + duration
  - 1. Durations: "ek hafte / 1 hafte / one week / for a week" = 7 days;
  "<n> din tak" / "for <n> days" = n days (ek/do/teen/chaar/paanch = 1..5).
    * "kal se ek hafte tak khana mat dena" -> start = message date + 1, end =
      start + 6 (7 days), and it cancels BOTH meals every day: lunchDelta -1,
      dinnerDelta -1.
    * "aaj se 2 din khana band" -> start = message date, end = start + 1.
  The deltas are PER DAY (each day in the range), so a pause is -1/-1, NOT the
  duration number. If there is no duration, set requestEndDate to null.
- "khana mat dena" / "khana band" / "mess band" / "food/meal mat dena" with no
  specific meal named = both meals: lunchDelta -1, dinnerDelta -1. If only lunch
  or only dinner is named, change just that meal.
- confidence is 0..1; use low confidence for ambiguous messages.
- If a message has no timestamp/date context, lean toward lower confidence when
  the timing is what makes it actionable.
- Return ONLY actionable/relevant requests. Ignore greetings, emoji-only lines,
  "<Media omitted>", deleted messages, links, and unrelated chatter.

Messages:
"""
${lines.slice(0, 20000)}
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

function normalizeRequest(
  r: any,
  today: string,
  messageTs: Date | null = null,
): ExtractedRequest | null {
  if (!r || typeof r !== "object") return null;
  const originalMessage = String(r.originalMessage ?? r.original_message ?? "").trim();
  if (originalMessage === "") return null;

  let requestType = String(r.requestType ?? r.request_type ?? "unclear");
  if (!REQUEST_TYPES.includes(requestType)) requestType = "unclear";

  let mealType = String(r.mealType ?? r.meal_type ?? "none");
  if (!MEAL_TYPES.includes(mealType)) mealType = "none";

  // Quantity deltas. Prefer the model's explicit numbers; otherwise derive them
  // from the request type + meal + a quantity parsed from the message. Non-meal
  // types never carry a delta, so a note/payment can't move a cook count.
  let lunchDelta = 0;
  let dinnerDelta = 0;
  if (["add_meal", "cancel_meal", "both_meals_cancel"].includes(requestType)) {
    const rawL = r.lunchDelta ?? r.lunch_delta;
    const rawD = r.dinnerDelta ?? r.dinner_delta;
    if (rawL != null && Number.isFinite(Number(rawL)) &&
        rawD != null && Number.isFinite(Number(rawD))) {
      lunchDelta = clampDelta(Number(rawL));
      dinnerDelta = clampDelta(Number(rawD));
    } else {
      // A date-range pause is a per-day -1, so a duration number ("3 din") must
      // not be read as the meal quantity. Force quantity 1 when a duration is
      // present; otherwise use the normal quantity parser.
      const qty = detectDurationDays(originalMessage) != null
        ? 1
        : detectQuantity(normalize(originalMessage));
      const d = deltasFor(requestType, mealType, qty);
      lunchDelta = d.lunch;
      dinnerDelta = d.dinner;
    }
  }

  let confidence = Number(r.confidence);
  if (!isFinite(confidence)) confidence = 0.5;
  confidence = Math.max(0, Math.min(1, confidence));

  // Date priority (req. 6): an explicit yyyy-mm-dd the model already resolved
  // wins; otherwise resolve a relative word (aaj/kal/parso/…) against the
  // MESSAGE timestamp; otherwise leave it null for the existing default path.
  let dateLabel = String(r.dateLabel ?? r.date_label ?? "unspecified").trim() ||
    "unspecified";
  let requestDate: string | null = null;
  const range = resolveMealDateRangeFromText(originalMessage, messageTs, today);
  const rawDate = r.requestDate ?? r.request_date;
  if (typeof rawDate === "string" && /^\d{4}-\d{2}-\d{2}$/.test(rawDate)) {
    requestDate = rawDate;
  } else {
    requestDate = range.startDate;
    if (range.label !== "unspecified") dateLabel = range.label;
  }

  // End date (req.): an explicit yyyy-mm-dd the model resolved wins (kept only
  // when it is on/after the start); otherwise derive it from a duration phrase.
  // null = single-day request.
  let requestEndDate: string | null = null;
  const rawEnd = r.requestEndDate ?? r.request_end_date;
  if (
    typeof rawEnd === "string" && /^\d{4}-\d{2}-\d{2}$/.test(rawEnd) &&
    requestDate && rawEnd > requestDate
  ) {
    requestEndDate = rawEnd;
  } else if (range.endDate && requestDate && range.endDate > requestDate) {
    requestEndDate = range.endDate;
  }

  return {
    studentName: String(r.studentName ?? r.student_name ?? "Unknown").trim() ||
      "Unknown",
    originalMessage,
    requestType,
    mealType,
    lunchDelta,
    dinnerDelta,
    dateLabel,
    requestDate,
    requestEndDate,
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
    } else if (isGroupSystemLine(line)) {
      // Join/add events and group notices (encryption notice, "You created
      // this group", invite-link line, etc.) are NOT chat messages. Skip them
      // entirely so they never merge into a meal request's text. Roster join
      // events are handled separately by parseRosterEvents.
      push();
      current = null;
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
    lunch: null,
    dinner: null,
    cutoffMinutes: DEFAULT_CUTOFF_MINUTES,
  };
  try {
    const { data } = await supabase
      .from("owner_profiles")
      .select("lunch_time, dinner_time, request_cutoff_minutes")
      .eq("id", ownerId)
      .maybeSingle();
    if (!data) return fallback;
    const cm = Number(data.request_cutoff_minutes);
    return {
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
  // Resolve the meal date(s) against the MESSAGE timestamp (not the import
  // date), falling back to `today` only when the message has no usable
  // timestamp. A duration ("ek hafte tak", "2 din") yields an inclusive end
  // date for a multi-day pause; otherwise endDate is null (single day).
  const {
    label: dateLabel,
    startDate: requestDate,
    endDate: requestEndDate,
    durationDays,
  } = resolveMealDateRangeFromText(text, parseTimestamp(msg.dateText), today);

  let requestType: string | null = null;
  let confidence = 0.55;

  const cancelWords = has([
    "cancel", "nahi chahiye", "nhi chahiye", "nahin chahiye", "mat banana",
    "mat bhejna", "mat dena", "skip", "nahi banana", "no lunch", "no dinner",
    "band karo", "kam", "hata", "ghata", "remove",
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

  let finalMeal = requestType === "both_meals_cancel" ? "both" : mealType;
  // "khana mat dena" / "khana band" / "mess band" / "food/meal band" with no
  // specific meal named = BOTH meals cancelled (lunch -1, dinner -1 per day).
  if (
    requestType === "cancel_meal" && finalMeal === "none" &&
    /(khana|khane|food|meal|mess|tiffin|dabba)/.test(lower)
  ) {
    requestType = "both_meals_cancel";
    finalMeal = "both";
  }

  // For a date-range pause/cancel each day is a per-day change (-1), so the
  // duration number ("3 din") must NOT be read as the meal quantity. Force the
  // quantity to 1 whenever a duration was detected; otherwise use the normal
  // quantity parser ("do lunch extra" -> 2).
  const qty = durationDays != null ? 1 : detectQuantity(lower);
  const { lunch, dinner } = deltasFor(requestType, finalMeal, qty);

  return {
    studentName: cleanSender(msg.sender),
    originalMessage: text,
    requestType,
    mealType: finalMeal,
    lunchDelta: lunch,
    dinnerDelta: dinner,
    dateLabel,
    requestDate,
    requestEndDate,
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
