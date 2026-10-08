// Keyword moderation (feature 6).
//
// The cheap, deterministic half of content moderation: a term list that turns a
// message or listing into an auto-filed report a human then triages in the admin
// console. Deliberately not a blocker: nothing is deleted or hidden, since a silently dropped real message
// is worse than a report a moderator dismisses. Image moderation needs the paid Cloud Vision API and is in TODO_MANUAL.md.

// Matched case-insensitively against whole words ("assist" doesn't trip "ass"), grouped by what a hit suggests, which tells a moderator how urgent it is.
const TERM_GROUPS: Record<string, string[]> = {
  // Attempts to move money, which FreeBNB never does: the most reliable scam signal on a free-stay platform.
  payment: [
    "wire transfer", "western union", "moneygram", "bitcoin", "crypto wallet",
    "gift card", "zelle", "cashapp", "cash app", "venmo me", "deposit required",
    "security deposit", "wire the money", "send payment",
  ],
  // Moving the conversation somewhere unlogged, a precursor to fraud and harassment.
  offPlatform: [
    "whatsapp", "telegram", "signal me", "text me at", "call me at", "email me at",
  ],
  // Sexual solicitation and trafficking indicators.
  exploitation: [
    "escort", "sugar daddy", "sugar baby", "full service", "in exchange for sex",
    "sexual favors", "pay for sex",
  ],
  // Threats and slurs, kept short: a long slur list in a public repo is its own problem and the human queue is the defence.
  abuse: [
    "kill you", "kill yourself", "kys", "rape", "i will hurt you", "beat you up",
  ],
};

export type ModerationHit = {
  /** Which groups tripped, e.g. ["payment", "offPlatform"]. */
  categories: string[];
  /** The exact terms matched, for the moderator's report. */
  terms: string[];
};

/** Escapes a term for literal use inside a RegExp. */
function escapeRegExp(term: string): string {
  return term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Pre-compiled once at load; `\b` on both ends gives whole-word matching, and multi-word terms match across one space run.
const COMPILED: { category: string; term: string; pattern: RegExp }[] =
  Object.entries(TERM_GROUPS).flatMap(([category, terms]) =>
    terms.map((term) => ({
      category,
      term,
      pattern: new RegExp(`\\b${escapeRegExp(term).replace(/\s+/g, "\\s+")}\\b`, "i"),
    }))
  );

/**
 * Scans free text for banned terms. Returns null when nothing matched, which is
 * the overwhelmingly common case and the one the caller should treat as free.
 */
export function scanText(text: string | undefined | null): ModerationHit | null {
  if (!text) return null;
  const categories = new Set<string>();
  const terms: string[] = [];
  for (const { category, term, pattern } of COMPILED) {
    if (pattern.test(text)) {
      categories.add(category);
      terms.push(term);
    }
  }
  if (terms.length === 0) return null;
  return { categories: [...categories].sort(), terms };
}

/** The `reason` string an auto-filed report carries into the triage queue. */
export function autoReportReason(hit: ModerationHit): string {
  return `Automatic keyword flag (${hit.categories.join(", ")}): ${hit.terms.join(", ")}`;
}
