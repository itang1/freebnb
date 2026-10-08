"use strict";
//
// The `searchTerms` index on the public user doc, in Node.
//
// This is the twin of `UserSearchTerms` in freebnb/Shared/UserProfileRepository.swift
// — the client writes these terms on every name change, and the backfill and seed write the same ones. The two
// implementations must agree exactly (a document indexed one way and queried the other is unfindable); change both
// and re-run the backfill. firestore.rules `isValidSearchTerms` enforces at most MAX_TERMS and the whole
// lowercased displayName.

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
  // Sorted for a stable array (a set would rewrite the field every save). Order isn't load-bearing, since
  // arrayContains ignores it
  // and Swift's sort can differ on non-ASCII, but the set of terms must match.
  return [fullName, ...[...terms].sort().slice(0, MAX_TERMS - 1)];
}

module.exports = { searchTerms, words, MAX_PREFIX_LENGTH, MAX_TERMS };
