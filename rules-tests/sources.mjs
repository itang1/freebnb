// Readers and parsers for the repo's other sources of truth: the Swift app,
// the Cloud Functions, the admin console, and the seed/backfill scripts.
//
// Several values are deliberately duplicated across those surfaces (caps,
// enum whitelists, id formats), because rules, Swift and TypeScript can't share code. mirrors.test.mjs uses these
// parsers to assert the copies agree, and messages.test.mjs to drive the rules with the client's real event kinds.
// Every parser throws when its pattern stops matching, so a moved constant fails loudly instead of rotting into a vacuous pass.

import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const repoRoot = fileURLToPath(new URL("..", import.meta.url));

export function read(relPath) {
  return readFileSync(repoRoot + relPath, "utf8");
}

/** Whether the repo publishes a file at this path. For assertions that want to
 *  say what is missing rather than let `read` throw ENOENT. */
export function exists(relPath) {
  return existsSync(repoRoot + relPath);
}

/** The slice of `text` between two markers; throws if either is missing. */
export function section(text, startMarker, endMarker, label) {
  const start = text.indexOf(startMarker);
  if (start === -1) {
    throw new Error(`${label}: start marker not found: ${JSON.stringify(startMarker)}`);
  }
  const end = text.indexOf(endMarker, start + startMarker.length);
  if (end === -1) {
    throw new Error(`${label}: end marker not found: ${JSON.stringify(endMarker)}`);
  }
  return text.slice(start, end);
}

/** The first capture group of `re` in `text` as a number; throws if absent. */
export function number(text, re, label) {
  const match = text.match(re);
  if (!match) throw new Error(`${label}: pattern not found: ${re}`);
  return Number(match[1]);
}

/**
 * Every single- or double-quoted string in `text`, in order. Line comments are
 * dropped first so an apostrophe in prose ("the listing's address") cannot open
 * a phantom string, and each match closes with the quote character it opened
 * with.
 */
export function quoted(text) {
  const uncommented = text.replace(/\/\/.*$/gm, "");
  return [...uncommented.matchAll(/"([^"]+)"|'([^']+)'/g)].map((m) => m[1] ?? m[2]);
}

/**
 * The raw values of a Swift enum's cases inside an already-sliced block.
 * Handles both spellings the app uses:
 *   case pending = "pending"          (explicit raw value)
 *   case requested, offered, modified (raw value defaults to the case name)
 * Lines like `case .pending: return "Pending"` inside a switch never match:
 * the first form requires `=`, the second anchors to the end of the line.
 */
export function swiftEnumCases(block) {
  const explicit = [...block.matchAll(/^\s*case\s+\w+\s*=\s*"([^"]+)"\s*$/gm)].map((m) => m[1]);
  if (explicit.length > 0) return explicit;
  return [...block.matchAll(/^\s*case\s+([a-zA-Z_]\w*(?:\s*,\s*[a-zA-Z_]\w*)*)\s*$/gm)]
    .flatMap((m) => m[1].split(",").map((name) => name.trim()));
}

/** StayEvent.Kind raw values, straight from the Swift client. */
export function swiftStayEventKinds() {
  const swift = read("freebnb/Shared/MessageStore.swift");
  const kinds = swiftEnumCases(section(swift, "enum Kind: String", "\n    }", "StayEvent.Kind"));
  if (kinds.length === 0) throw new Error("StayEvent.Kind: no cases parsed");
  return kinds;
}

/**
 * The stored property names of StayEvent — the exact key set the encoder can
 * put on `event`. Computed properties are skipped: their declaration opens a
 * brace, a stored one ends at the type.
 *
 * The kind list was mirrored and the key list was not, which is how a kind got
 * whitelisted while the field it always carries stayed rejected. Both halves
 * are parsed now.
 */
export function swiftStayEventFields() {
  const swift = read("freebnb/Shared/MessageStore.swift");
  const block = section(swift, "struct StayEvent", "\n}", "StayEvent");
  const fields = [...block.matchAll(/^ {4}(?:let|var) (\w+): [^\n{]+$/gm)].map((m) => m[1]);
  if (fields.length === 0) throw new Error("StayEvent: no stored properties parsed");
  return fields;
}
