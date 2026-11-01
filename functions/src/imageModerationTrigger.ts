// Image moderation for listing photos: the Storage trigger.
//
// Every finalized object under listings/{hostUserID}/{homeID}/ is sent to Cloud Vision SafeSearch by its
// gs:// URI (Vision reads the bucket itself, so the image never passes through the function). A photo that
// crosses the thresholds in imageModeration.ts files a report into the same `reports` queue as keyword
// moderation, tagged `source: "auto"`. Nothing is deleted or hidden; a moderator decides.
//
// Setup, once per project (paid API, so it isn't on by default):
//   1. Enable the Cloud Vision API: gcloud services enable vision.googleapis.com
//   2. The function's runtime service account needs no extra role for Vision itself, but must be able to read
//      the bucket, which the default compute/App Engine account already can.
// Until the API is enabled every upload logs an error here and no report is filed; uploads are unaffected.

import * as admin from "firebase-admin";
import * as logger from "firebase-functions/logger";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { ImageAnnotatorClient } from "@google-cloud/vision";
import { Collections } from "./paths";
import {
  evaluateSafeSearch,
  imageReportID,
  imageReportReason,
  parseListingPhotoPath,
} from "./imageModeration";

// Created on first use so a cold start that never sees a listing photo doesn't pay for the client.
let vision: ImageAnnotatorClient | undefined;
function visionClient(): ImageAnnotatorClient {
  vision ??= new ImageAnnotatorClient();
  return vision;
}

export const moderateListingPhoto = onObjectFinalized(async (event) => {
  const { name, bucket, contentType } = event.data;
  const photo = parseListingPhotoPath(name);
  // storage.rules already restricts this prefix to images; the check keeps a server-written non-image (a
  // future thumbnail manifest, say) from costing a Vision call.
  if (!photo || !contentType?.startsWith("image/")) return;

  let annotation;
  try {
    const [result] = await visionClient().safeSearchDetection(`gs://${bucket}/${name}`);
    if (result.error?.message) throw new Error(result.error.message);
    annotation = result.safeSearchAnnotation;
  } catch (err) {
    // A host who removed the photo, or a deleted account's cascade, can beat the trigger to the object; that
    // and a disabled API are both "nothing to moderate", not something a retry fixes.
    logger.error("SafeSearch failed for listing photo", { name, error: String(err) });
    return;
  }

  const hit = evaluateSafeSearch(annotation);
  if (!hit) return;

  await admin.firestore().collection(Collections.reports).doc(imageReportID(photo)).set({
    // The uploader, as keyword reports use the author: the account deletion cascade clears these with them.
    reporterUserID: photo.hostUserID,
    targetType: "listing",
    targetID: photo.homeID,
    reason: imageReportReason(hit, name),
    status: "new",
    source: "auto",
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });
  logger.info("Auto-filed image moderation report", { homeID: photo.homeID, categories: hit.categories });
});
