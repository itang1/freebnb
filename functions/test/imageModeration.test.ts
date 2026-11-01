// Decision logic for listing photo moderation. Run with `npm test` (compiles to lib-test/, then node --test).
import { test } from "node:test";
import * as assert from "node:assert/strict";
import {
  DEFAULT_THRESHOLDS,
  evaluateSafeSearch,
  imageReportID,
  imageReportReason,
  normaliseLikelihood,
  parseListingPhotoPath,
} from "../src/imageModeration";

const clean = { adult: "VERY_UNLIKELY", violence: "VERY_UNLIKELY", racy: "UNLIKELY", medical: "UNLIKELY", spoof: "UNLIKELY" };

test("a clean photo files nothing", () => {
  assert.equal(evaluateSafeSearch(clean), null);
});

test("missing annotation fails open", () => {
  assert.equal(evaluateSafeSearch(null), null);
  assert.equal(evaluateSafeSearch(undefined), null);
  assert.equal(evaluateSafeSearch({}), null);
});

test("adult and violence report at LIKELY, not POSSIBLE", () => {
  assert.equal(evaluateSafeSearch({ ...clean, adult: "POSSIBLE" }), null);
  assert.deepEqual(evaluateSafeSearch({ ...clean, adult: "LIKELY" }), {
    categories: ["adult"],
    likelihoods: { adult: "LIKELY" },
  });
  assert.equal(evaluateSafeSearch({ ...clean, violence: "POSSIBLE" }), null);
  assert.deepEqual(evaluateSafeSearch({ ...clean, violence: "VERY_LIKELY" })?.categories, ["violence"]);
});

test("racy needs VERY_LIKELY so pool and swimsuit photos pass", () => {
  assert.equal(evaluateSafeSearch({ ...clean, racy: "LIKELY" }), null);
  assert.deepEqual(evaluateSafeSearch({ ...clean, racy: "VERY_LIKELY" })?.categories, ["racy"]);
});

test("medical and spoof never report", () => {
  assert.equal(evaluateSafeSearch({ ...clean, medical: "VERY_LIKELY", spoof: "VERY_LIKELY" }), null);
});

test("several categories are reported together in a fixed order", () => {
  const hit = evaluateSafeSearch({ racy: "VERY_LIKELY", violence: "LIKELY", adult: "VERY_LIKELY" });
  assert.deepEqual(hit, {
    categories: ["adult", "violence", "racy"],
    likelihoods: { adult: "VERY_LIKELY", violence: "LIKELY", racy: "VERY_LIKELY" },
  });
});

test("numeric enum values are understood", () => {
  // 4 = LIKELY, 5 = VERY_LIKELY in Vision's Likelihood enum.
  assert.equal(normaliseLikelihood(4), "LIKELY");
  assert.deepEqual(evaluateSafeSearch({ adult: 4 })?.categories, ["adult"]);
  assert.equal(evaluateSafeSearch({ racy: 4 }), null);
});

test("unknown or garbage values never report, even at a permissive threshold", () => {
  assert.equal(normaliseLikelihood("SOMETIMES"), "UNKNOWN");
  assert.equal(normaliseLikelihood(99), "UNKNOWN");
  assert.equal(normaliseLikelihood(null), "UNKNOWN");
  const everything = { adult: "UNKNOWN", violence: "UNKNOWN", racy: "UNKNOWN" } as const;
  assert.equal(evaluateSafeSearch({ adult: "UNKNOWN", violence: "nope", racy: undefined }, everything), null);
});

test("custom thresholds are honoured", () => {
  const strict = { ...DEFAULT_THRESHOLDS, racy: "POSSIBLE" } as const;
  assert.deepEqual(evaluateSafeSearch({ ...clean, racy: "POSSIBLE" }, strict)?.categories, ["racy"]);
});

test("only listings/{host}/{home}/{file} paths are listing photos", () => {
  assert.deepEqual(parseListingPhotoPath("listings/u1/h1/abc.jpg"), {
    hostUserID: "u1",
    homeID: "h1",
    fileName: "abc.jpg",
  });
  for (const name of [
    undefined,
    null,
    "",
    "listings/u1/abc.jpg",
    "listings/u1/h1/sub/abc.jpg",
    "listings//h1/abc.jpg",
    "listings/u1/h1/",
    "avatars/u1/h1/abc.jpg",
    "backups/listings/u1/h1",
  ]) {
    assert.equal(parseListingPhotoPath(name), null, String(name));
  }
});

test("report id is per photo and distinct from the keyword report", () => {
  const a = imageReportID({ hostUserID: "u1", homeID: "h1", fileName: "a.jpg" });
  const b = imageReportID({ hostUserID: "u1", homeID: "h1", fileName: "b.jpg" });
  assert.equal(a, "auto_image_h1_a.jpg");
  assert.notEqual(a, b);
  assert.notEqual(a, "auto_listing_h1");
  assert.ok(!a.includes("/"));
});

test("reason names the categories, likelihoods and photo and fits the reports limit", () => {
  const hit = evaluateSafeSearch({ adult: "VERY_LIKELY", racy: "VERY_LIKELY" })!;
  const reason = imageReportReason(hit, "listings/u1/h1/a.jpg");
  assert.equal(
    reason,
    "Automatic image flag (adult, racy): adult VERY_LIKELY, racy VERY_LIKELY. Photo: listings/u1/h1/a.jpg"
  );
  assert.ok(reason.length < 2000);
});
