// Keyword moderation (feature 6).
//
// The cheap, deterministic half of content moderation: a term list that turns a
// message or listing into an auto-filed report a human then triages in the admin
// console. It is deliberately *not* a blocker — nothing is deleted or hidden
// automatically, because a false positive that silently drops a real message is
// worse than a queued report a moderator dismisses in a second.
//
// Image moderation (the other half of feature 6) needs the Cloud Vision API,
// which is a paid, per-request service. It is written up in TODO_MANUAL.md
// rather than stubbed here.

// Matched case-insensitively against whole words, so "assist" does not trip
// "ass" and "Scunthorpe" survives. Grouped by what a hit actually suggests,
// because the group is what tells a moderator how urgently to look.
const TERM_GROUPS: Record<string, string[]> = {
  // Attempts to move money, which FreeBNB does not do at all: the single most
  // reliable scam signal on a free-stay platform.
  payment: [
    "wire transfer", "western union", "moneygram", "bitcoin", "crypto wallet",
    "gift card", "zelle", "cashapp", "cash app", "venmo me", "deposit required",
    "security deposit", "wire the money", "send payment",
  ],
  // Moving the conversation somewhere unlogged, the standard precursor to both
  // fraud and harassment.
  offPlatform: [
    "whatsapp", "telegram", "signal me", "text me at", "call me at", "email me at",
  ],
  // Sexual solicitation and trafficking indicators.
  exploitation: [
    "escort", "sugar daddy", "sugar baby", "full service", "in exchange for sex",
    "sexual favors", "pay for sex",
  ],
  // Threats and slurs. Kept short on purpose: a long slur list in a public repo
  // is its own problem, and the real defence is the human queue.
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

// Pre-compiled once at module load rather than per invocation. `\b` on both ends
// gives whole-word matching; multi-word terms match across a single space run.
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
