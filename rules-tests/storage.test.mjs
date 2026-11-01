// Listing photos are private to a listing's audience, and Storage rules can't see that
// audience (it lives in Firestore). So no client reads a photo object directly: everyone,
// the host included, gets a short-lived signed URL from the `listingPhotoURLs` callable.
// Pinned boundaries:
//   - nobody gets or lists a listing photo through the client SDK, not even the host;
//   - only the host writes or deletes under their own listing folder;
//   - anonymous sessions write nothing;
//   - uploads must be images under 10 MB.

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { after, before, beforeEach, describe, it } from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import { deleteObject, getBytes, getDownloadURL, getMetadata, listAll, ref, uploadBytes } from "firebase/storage";

const rulesPath = fileURLToPath(new URL("../storage.rules", import.meta.url));

const HOST = "user-host";
const FRIEND = "user-friend";
const STRANGER = "user-stranger";
const PHOTO = `listings/${HOST}/listing-1/0b6f1c9e-2d1a-4c55-9d0a-7d2f3a1e9b10.jpg`;
const JPEG = new Uint8Array([0xff, 0xd8, 0xff, 0xd9]);

let testEnv;

const storageAs = (uid) => testEnv.authenticatedContext(uid).storage();
const anonymousStorage = (uid) =>
  testEnv.authenticatedContext(uid, { firebase: { sign_in_provider: "anonymous" } }).storage();

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: "freebnb-rules-tests",
    storage: { rules: readFileSync(rulesPath, "utf8") },
  });
});

after(async () => {
  await testEnv?.cleanup();
});

beforeEach(async () => {
  await testEnv.clearStorage();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await uploadBytes(ref(context.storage(), PHOTO), JPEG, { contentType: "image/jpeg" });
  });
});

describe("listing photos: reads", () => {
  for (const [who, storage] of [
    ["the host", () => storageAs(HOST)],
    ["a friend", () => storageAs(FRIEND)],
    ["a stranger", () => storageAs(STRANGER)],
    ["an anonymous session", () => anonymousStorage(STRANGER)],
    ["a signed-out client", () => testEnv.unauthenticatedContext().storage()],
  ]) {
    it(`${who} can't download, fetch a download URL, read metadata, or list`, async () => {
      const s = storage();
      await assertFails(getBytes(ref(s, PHOTO)));
      await assertFails(getDownloadURL(ref(s, PHOTO)));
      await assertFails(getMetadata(ref(s, PHOTO)));
      await assertFails(listAll(ref(s, `listings/${HOST}/listing-1`)));
    });
  }
});

describe("listing photos: writes", () => {
  const newPhoto = `listings/${HOST}/listing-1/4c1e7a52-8f0b-4f7d-9a9e-1b2c3d4e5f60.jpg`;

  it("the host uploads a JPEG to their own listing", async () => {
    await assertSucceeds(uploadBytes(ref(storageAs(HOST), newPhoto), JPEG, { contentType: "image/jpeg" }));
  });

  it("the host deletes their own photo", async () => {
    await assertSucceeds(deleteObject(ref(storageAs(HOST), PHOTO)));
  });

  it("a non-image upload is rejected", async () => {
    await assertFails(uploadBytes(ref(storageAs(HOST), newPhoto), JPEG, { contentType: "text/html" }));
  });

  it("an upload of 10 MB or more is rejected", async () => {
    const big = new Uint8Array(10 * 1024 * 1024);
    await assertFails(uploadBytes(ref(storageAs(HOST), newPhoto), big, { contentType: "image/jpeg" }));
  });

  it("someone else can't upload into or delete from the host's folder", async () => {
    await assertFails(uploadBytes(ref(storageAs(FRIEND), newPhoto), JPEG, { contentType: "image/jpeg" }));
    await assertFails(deleteObject(ref(storageAs(FRIEND), PHOTO)));
  });

  it("an anonymous session can't write even under its own uid", async () => {
    const own = `listings/${STRANGER}/listing-9/x.jpg`;
    await assertFails(uploadBytes(ref(anonymousStorage(STRANGER), own), JPEG, { contentType: "image/jpeg" }));
  });

  it("nothing outside listings/ is writable", async () => {
    await assertFails(uploadBytes(ref(storageAs(HOST), `avatars/${HOST}.jpg`), JPEG, { contentType: "image/jpeg" }));
  });
});
