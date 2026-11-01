// Image moderation for listing photos: the decision half.
//
// Cloud Vision SafeSearch rates each uploaded photo on a five-step likelihood scale per category. This module
// turns those ratings into "file a report or not" and the report's text; the Storage trigger that calls
// Vision and writes the report is in imageModerationTrigger.ts. Kept free of Firebase and Vision imports so
// the decision logic is testable on its own.
//
// Same policy as keyword moderation (moderation.ts): a hit files a report into the human triage queue and
// nothing is deleted or hidden. SafeSearch misfires on swimsuits, art and medical photos, and a host's
// legitimate photo silently vanishing is worse than a moderator dismissing a report.

/** SafeSearch's likelihood scale, least to most likely. */
export const LIKELIHOODS = [
  "UNKNOWN",
  "VERY_UNLIKELY",
  "UNLIKELY",
  "POSSIBLE",
  "LIKELY",
  "VERY_LIKELY",
] as const;

export type Likelihood = (typeof LIKELIHOODS)[number];

/** The categories SafeSearch returns. Vision's client types allow numbers or strings, so values are loose. */
export type SafeSearchAnnotation = Partial<
  Record<"adult" | "violence" | "racy" | "medical" | "spoof", string | number | null | undefined>
>;

export type ImageCategory = "adult" | "violence" | "racy";

/**
 * The likelihood at or above which a category files a report. `adult` and `violence` have no place in a
 * listing and report at LIKELY; `racy` also fires on swimsuits and pool photos, which listings legitimately
 * have, so it needs VERY_LIKELY. `medical` and `spoof` (memes, edited images) aren't safety signals here.
 */
export const DEFAULT_THRESHOLDS: Record<ImageCategory, Likelihood> = {
  adult: "LIKELY",
  violence: "LIKELY",
  racy: "VERY_LIKELY",
};

export type ImageModerationHit = {
  /** Which categories crossed their threshold, in a fixed order: adult, violence, racy. */
  categories: ImageCategory[];
  /** The likelihood SafeSearch gave each tripped category, for the moderator's report. */
  likelihoods: Partial<Record<ImageCategory, Likelihood>>;
};

/**
 * Normalises a SafeSearch value to a likelihood name. The Vision client returns the enum name ("LIKELY") by
 * default but its types also allow the enum number; anything unrecognised is UNKNOWN, which never reports.
 */
export function normaliseLikelihood(value: string | number | null | undefined): Likelihood {
  if (typeof value === "number") return LIKELIHOODS[value] ?? "UNKNOWN";
  if (typeof value === "string" && (LIKELIHOODS as readonly string[]).includes(value)) {
    return value as Likelihood;
  }
  return "UNKNOWN";
}

function rank(likelihood: Likelihood): number {
  return LIKELIHOODS.indexOf(likelihood);
}

/**
 * Decides whether a photo's SafeSearch ratings warrant a report. Returns null when nothing crossed its
 * threshold, the overwhelmingly common case. A missing annotation (Vision returned nothing) is null too:
 * failing open matches the rest of moderation, and the human report button is still there.
 */
export function evaluateSafeSearch(
  annotation: SafeSearchAnnotation | null | undefined,
  thresholds: Record<ImageCategory, Likelihood> = DEFAULT_THRESHOLDS
): ImageModerationHit | null {
  if (!annotation) return null;
  const categories: ImageCategory[] = [];
  const likelihoods: Partial<Record<ImageCategory, Likelihood>> = {};
  for (const category of ["adult", "violence", "racy"] as const) {
    const likelihood = normaliseLikelihood(annotation[category]);
    // UNKNOWN ranks lowest, so it can't cross a threshold; guard anyway so a threshold of UNKNOWN can't make
    // every photo report.
    if (likelihood !== "UNKNOWN" && rank(likelihood) >= rank(thresholds[category])) {
      categories.push(category);
      likelihoods[category] = likelihood;
    }
  }
  return categories.length === 0 ? null : { categories, likelihoods };
}

export type ListingPhotoPath = { hostUserID: string; homeID: string; fileName: string };

/**
 * Parses a Storage object name into the listing it belongs to. Listing photos live at
 * listings/{hostUserID}/{homeID}/{file} (paths.ts, storage.rules); anything else, including deeper paths and
 * empty segments, is null so the trigger ignores it.
 */
export function parseListingPhotoPath(objectName: string | undefined | null): ListingPhotoPath | null {
  if (!objectName) return null;
  const parts = objectName.split("/");
  if (parts.length !== 4 || parts[0] !== "listings") return null;
  const [, hostUserID, homeID, fileName] = parts;
  if (!hostUserID || !homeID || !fileName) return null;
  return { hostUserID, homeID, fileName };
}

/**
 * The report document id for one photo. Per photo, not per listing, so it neither overwrites nor is
 * overwritten by the listing's keyword report (`auto_listing_{homeID}`), and two flagged photos are two
 * reports. Firestore ids can't contain "/", which the parsed segments never do.
 */
export function imageReportID(photo: ListingPhotoPath): string {
  return `auto_image_${photo.homeID}_${photo.fileName}`;
}

/** The `reason` string an auto-filed image report carries into the triage queue. */
export function imageReportReason(hit: ImageModerationHit, objectName: string): string {
  const detail = hit.categories.map((c) => `${c} ${hit.likelihoods[c]}`).join(", ");
  return `Automatic image flag (${hit.categories.join(", ")}): ${detail}. Photo: ${objectName}`;
}
