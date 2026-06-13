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
//   6. resolve / create the customer (`students`) for each request
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
    if (processed.length > 0) {
      const rows = processed.map((m) => {
        const ts = parseTimestamp(m.dateText);
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
    const studentIds = await resolveStudentIds(
      supabase,
      ownerId,
      requests.map((r) => r.studentName),
    );

    // --- Duplicate detection (deterministic, no embeddings) ------------
    // Key = customer + meal + action(request_type) + date. Match against
    // recent existing requests, then against earlier rows in this batch.
    const existingByKey = await loadExistingDupKeys(supabase, ownerId);
    const batchFirstIndexByKey = new Map<string, number>();

    interface PendingDup {
      index: number;
      duplicateOf: string | null; // existing meal_requests.id, or null = within-batch
      batchIndex: number | null; // earlier index in this batch, or null = existing
    }
    const dupPlans: PendingDup[] = [];

    const rows = requests.map((r, i) => {
      const sKey = nameKey(r.studentName);
      const key = dupKey(sKey, r);
      let duplicateStatus = "unique";

      const existingId = existingByKey.get(key);
      const earlierIndex = batchFirstIndexByKey.get(key);
      if (existingId) {
        duplicateStatus = "possible_duplicate";
        dupPlans.push({ index: i, duplicateOf: existingId, batchIndex: null });
      } else if (earlierIndex !== undefined) {
        duplicateStatus = "possible_duplicate";
        dupPlans.push({ index: i, duplicateOf: null, batchIndex: earlierIndex });
      } else {
        batchFirstIndexByKey.set(key, i);
      }

      return {
        owner_id: ownerId,
        student_id: studentIds.get(sKey) ?? null,
        student_name: r.studentName,
        original_message: r.originalMessage,
        request_type: r.requestType,
        meal_type: r.mealType,
        request_date: r.requestDate,
        date_label: r.dateLabel,
        status: "pending", // confidence<0.6 / unclear are also pending (needs review)
        confidence: r.confidence,
        reason: r.reason,
        source,
        import_id: importId,
        message_id: messageIdByText.get(r.originalMessage) ?? null,
        duplicate_status: duplicateStatus,
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
            reason: "Same customer, meal, action and date as an earlier request.",
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

async function resolveStudentIds(
  supabase: SupabaseClient,
  ownerId: string,
  names: string[],
): Promise<Map<string, string>> {
  const distinct = new Map<string, string>(); // key -> display name
  for (const n of names) {
    const key = nameKey(n);
    if (key === "" || key === "unknown") continue;
    if (!distinct.has(key)) distinct.set(key, n.trim());
  }
  const result = new Map<string, string>();
  if (distinct.size === 0) return result;

  const { data: existing } = await supabase
    .from("students")
    .select("id, name")
    .eq("owner_id", ownerId);
  for (const s of existing ?? []) {
    const k = nameKey((s.name as string) ?? "");
    if (k && s.id) result.set(k, s.id as string);
  }

  // Aliases let alternate spellings resolve to the same student.
  const { data: aliases } = await supabase
    .from("student_aliases")
    .select("student_id, normalized_alias")
    .eq("owner_id", ownerId);
  for (const a of aliases ?? []) {
    const k = (a.normalized_alias as string) ?? "";
    if (k && a.student_id && !result.has(k)) result.set(k, a.student_id as string);
  }

  const toCreate = [...distinct.entries()].filter(([k]) => !result.has(k));
  if (toCreate.length > 0) {
    const { data: inserted, error } = await supabase
      .from("students")
      .insert(toCreate.map(([, name]) => ({ owner_id: ownerId, name })))
      .select("id, name");
    if (error) throw error;
    for (const s of inserted ?? []) {
      const k = nameKey((s.name as string) ?? "");
      if (k && s.id) result.set(k, s.id as string);
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Duplicate detection
// ---------------------------------------------------------------------------
function dupKey(studentKey: string, r: ExtractedRequest): string {
  const dateKey = r.requestDate ?? r.dateLabel ?? "";
  return [studentKey, r.requestType, r.mealType, dateKey].join("|");
}

async function loadExistingDupKeys(
  supabase: SupabaseClient,
  ownerId: string,
): Promise<Map<string, string>> {
  const map = new Map<string, string>();
  const { data } = await supabase
    .from("meal_requests")
    .select("id, student_name, request_type, meal_type, request_date, date_label")
    .eq("owner_id", ownerId)
    .in("status", ["pending", "approved"])
    .order("created_at", { ascending: false })
    .limit(1000);
  for (const row of data ?? []) {
    const key = dupKey(nameKey((row.student_name as string) ?? ""), {
      studentName: "",
      originalMessage: "",
      requestType: (row.request_type as string) ?? "unclear",
      mealType: (row.meal_type as string) ?? "none",
      dateLabel: (row.date_label as string) ?? "",
      requestDate: (row.request_date as string) ?? null,
      confidence: 0,
      reason: "",
    });
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
