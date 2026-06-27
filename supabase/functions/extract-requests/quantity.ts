// KotaMess Owner — quantity parsing for lunch/dinner meal-change requests.
//
// Real WhatsApp requests carry a number and a direction: "kal do lunch extra
// dena" = +2 lunches, "do dinner cancel kar dena" = -2 dinners. These helpers
// turn a (already-normalized, lowercase, alnum-only) message into signed
// per-meal deltas, and are shared by the Gemini-output normalizer and the
// rule-based fallback parser in index.ts. Kept in their own module so they can
// be unit-tested without importing the Edge Function entrypoint.

// Hindi/Hinglish number words. "do" = 2 is the important one for phrases like
// "do lunch extra" / "do dinner cancel"; the adjacency rule in detectQuantity
// keeps a trailing "kar do" ("do it") from being read as a number.
export const NUM_WORDS: Record<string, number> = {
  ek: 1, one: 1,
  do: 2, two: 2,
  teen: 3, three: 3,
  char: 4, chaar: 4, four: 4,
  paanch: 5, panch: 5, five: 5,
};

export const MEAL_WORD_RE =
  /^(lunch|lunches|dinner|dinners|khana|khane|tiffin|dabba|meal|meals|plate|plates|thali|thaali)$/;

export const MAX_MEAL_DELTA = 20; // sanity cap so a stray "100" can't wreck a count

export function tokenToNumber(tok: string): number | null {
  if (/^\d{1,2}$/.test(tok)) {
    const n = parseInt(tok, 10);
    return n > 0 ? n : null;
  }
  return tok in NUM_WORDS ? NUM_WORDS[tok] : null;
}

// The quantity for a meal change. A number word counts only when it sits next
// to a meal word ("do lunch", "3 dinner"), and a bare digit counts anywhere.
// A trailing "do" in "cancel kar do" is not meal-adjacent, so it stays 1.
export function detectQuantity(lower: string): number {
  const tokens = lower.split(" ").filter((t) => t !== "");
  for (let i = 0; i < tokens.length; i++) {
    const n = tokenToNumber(tokens[i]);
    if (n === null) continue;
    const prev = tokens[i - 1] ?? "";
    const next = tokens[i + 1] ?? "";
    if (MEAL_WORD_RE.test(prev) || MEAL_WORD_RE.test(next)) return n;
    if (/^\d{1,2}$/.test(tokens[i])) return n;
  }
  return 1;
}

export function clampDelta(n: number): number {
  if (!Number.isFinite(n)) return 0;
  const i = Math.trunc(n);
  return Math.max(-MAX_MEAL_DELTA, Math.min(MAX_MEAL_DELTA, i));
}

// Signed per-meal deltas derived from a classified request + a quantity.
// add_meal -> positive, cancel_meal / both_meals_cancel -> negative, every other
// type -> 0 (no quantity meaning).
export function deltasFor(
  requestType: string,
  mealType: string,
  qty: number,
): { lunch: number; dinner: number } {
  const q = Math.max(1, Math.min(MAX_MEAL_DELTA, Math.abs(Math.trunc(qty || 1))));
  if (requestType === "both_meals_cancel") return { lunch: -q, dinner: -q };
  const sign = requestType === "add_meal" ? 1 : requestType === "cancel_meal" ? -1 : 0;
  if (sign === 0) return { lunch: 0, dinner: 0 };
  return {
    lunch: mealType === "lunch" || mealType === "both" ? sign * q : 0,
    dinner: mealType === "dinner" || mealType === "both" ? sign * q : 0,
  };
}
