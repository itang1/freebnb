"use strict";
//
// The `searchTerms` index on the public user doc, in Node.
//
// This is the twin of `UserSearchTerms` in freebnb/Shared/UserProfileRepository.swift
// — the client writes these terms on every name change, and the backfill and the
// seed write the same ones. The two implementations must agree exactly: a
// document indexed one way and queried the other is a user nobody can find.
// If you change the rules here, change them there, and re-run the backfill.
//
// The firestore.rules `isValidSearchTerms` check enforces two of these
// properties server-side: at most MAX_TERMS entries, and the whole lowercased
// displayName among them.

const MAX_PREFIX_LENGTH = 15;
const MAX_TERMS = 60;

/** Lowercased words, split on anything that isn't a letter or a digit. */
function words(name) {
  return name
    .toLowerCase()
    .split(/[^\p{L}\p{N}]+/u)
    .filter((word) => word.length > 0);
}

/** Every prefix of every word, plus the whole lowercased name first. */
function searchTerms(displayName) {
  const terms = new Set();
  for (const word of words(displayName)) {
    const capped = word.slice(0, MAX_PREFIX_LENGTH);
    for (let length = 1; length <= capped.length; length++) {
      terms.add(capped.slice(0, length));
    }
  }
  const fullName = displayName.toLowerCase();
  terms.delete(fullName);
  // Sorted for a stable array: an unordered set would rewrite the field on
  // every save. Order is not load-bearing — arrayContains doesn't care, and
  // Swift's Unicode-aware sort and this code-unit sort can disagree on
  // non-ASCII names — but the *set* of terms must match.
  return [fullName, ...[...terms].sort().slice(0, MAX_TERMS - 1)];
}

module.exports = { searchTerms, words, MAX_PREFIX_LENGTH, MAX_TERMS };
