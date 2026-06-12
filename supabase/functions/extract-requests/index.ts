// KotaMess Owner — WhatsApp request extraction Edge Function.
//
// POST { chatText, source: "paste"|"file", today: "YYYY-MM-DD" }
// Requires a valid Supabase user JWT (sent automatically by the Flutter
// supabase client). Calls Gemini server-side to extract structured meal
// requests, and falls back to a local rule-based parser if Gemini is
// unavailable. The Gemini key NEVER leaves the server.
//
// Returns: { requests: ExtractedRequest[], warnings: string[] }
//
// Deploy:  supabase functions deploy extract-requests
// Secrets: supabase secrets set GEMINI_API_KEY=...
//          supabase secrets set GEMINI_MODEL=gemini-2.5-flash   (optional;
//          defaults to gemini-2.5-flash). The Gemini key is a server secret
//          only and is never logged or returned to the client.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ requests: [], warnings: ["Method not allowed."] }, 405);
  }

  // --- Auth: require a valid Supabase user JWT ---------------------------
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return json({ requests: [], warnings: ["Not authenticated."] }, 401);
  }
  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL") ?? "",
      Deno.env.get("SUPABASE_ANON_KEY") ?? "",
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: userData, error: userErr } = await supabase.auth.getUser();
    if (userErr || !userData?.user) {
      return json({ requests: [], warnings: ["Invalid or expired session."] }, 401);
    }
  } catch (_e) {
    return json({ requests: [], warnings: ["Auth check failed."] }, 401);
  }

  // --- Parse body -------------------------------------------------------
  let body: { chatText?: unknown; source?: unknown; today?: unknown } | null = null;
  try {
    body = await req.json();
  } catch (_e) {
    return json({ requests: [], warnings: ["Request body was not valid JSON."] }, 200);
  }

  const chatText = typeof body?.chatText === "string" ? body.chatText : "";
  if (chatText.trim() === "") {
    return json({ requests: [], warnings: ["No chat text provided."] }, 200);
  }
  const today =
    typeof body?.today === "string" && /^\d{4}-\d{2}-\d{2}$/.test(body.today)
      ? body.today
      : new Date().toISOString().slice(0, 10);

  const messages = parseWhatsApp(chatText);
  const warnings: string[] = [];
  let requests: ExtractedRequest[] | null = null;

  // --- Try Gemini, fall back on any failure -----------------------------
  const geminiKey = Deno.env.get("GEMINI_API_KEY");
  const geminiModel = Deno.env.get("GEMINI_MODEL") ?? "gemini-2.5-flash";
  if (geminiKey) {
    try {
      requests = await extractWithGemini(geminiKey, geminiModel, chatText, today);
      if (!requests || requests.length === 0) {
        // Gemini ran but found nothing actionable — trust it, but note it.
        requests = requests ?? [];
      }
    } catch (e) {
      warnings.push("Gemini extraction failed; used fallback parser.");
      requests = null;
    }
  } else {
    warnings.push("GEMINI_API_KEY not set; used fallback parser.");
  }

  if (requests === null) {
    requests = fallbackExtract(messages, today);
  }

  return json({ requests, warnings }, 200);
});

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

function detectDateLabel(lower: string, fallback: string): string {
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
