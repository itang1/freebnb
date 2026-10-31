# FreeBNB Roadmap

_Last updated: 2026-10-31_

This roadmap comes from a review of the codebase as of `0b8b026`. The app is in good shape: the core loop (list, browse, request, accept, message, review) is complete, security rules are the real authorization boundary and are tested against the emulator, and stores sit behind repository protocols. The biggest gaps are product gaps on the way to a real launch, not engineering debt.

Priorities are grouped as **Now** (blocks a credible launch), **Next** (the next one to two months), and **Later** (worth doing once people are using it). Each item says why it matters and where in the code it starts.

---

## The platform decision: stay on Firebase for now

The open question from recent sessions was whether to move from Firebase to Supabase, including image storage. **Recommendation: stay on Firebase through launch, and revisit only if a concrete limit bites.**

What a move would cost, from what is in the repo today:

- **Rules rewrite.** `firestore.rules` is about 1,450 lines and is pinned by 14 rules test files in `rules-tests/` plus the emulator-backed Swift suites. All of it would have to become Postgres row-level security policies and be re-verified.
- **Backend rewrite.** `functions/src/index.ts` holds 15 triggers and callables (listing ACL maintenance on friend-graph changes, stay lifecycle, push fan-out, moderation, account-deletion cascade, data export, backups). Most are Firestore document triggers that would become Postgres triggers, Edge Functions or webhooks.
- **Auth.** Apple, Google, email and anonymous sessions plus App Check are all wired. Supabase supports these, but every user would need migrating.
- **Real-time.** `MessageStore` and the feed rely on Firestore snapshot listeners and a collection-group query.

What a move would buy:

- **Real image ACLs.** This is the strongest argument. `storage.rules` explains that Storage rules cannot read Firestore, so photos cannot be locked to a listing's friends; the gate is "signed in, and you'd need to know the path." Supabase Storage policies are SQL and can join against the friend graph directly.
- **Relational queries.** The friend graph, circles and mutual-friend lookups are naturally relational, and some current denormalization (`allowedViewerIDs`, mirrors, search terms) exists to work around Firestore.

The repository seam (`Shared/*Repository.swift`) means a migration is possible later without touching views or stores. The image ACL problem can be solved on Firebase today (see item 2 below), which removes the main reason to move now. If the team still wants Supabase, a lower-risk path is a **time-boxed spike** (item 13): Supabase Storage only, using Supabase's third-party auth support for Firebase Auth tokens, so images move without moving data.

---

## Now: launch blockers

### 1. Ship listing photos
A home-sharing app without photos is the single largest product gap. Everything around it is already built: `Home.photoURLs` decodes, `storage.rules` is written and scoped per host and listing, and `PhotoUploader` is a protocol with a `NoopPhotoUploader` default that throws.
- Implement a `FirebaseStoragePhotoUploader` with **random per-upload filenames** (UUIDs). `storage.rules` already relies on unguessable paths and notes this as a requirement.
- Client-side downscale and JPEG/HEIC compression before upload, plus EXIF/GPS stripping so a host's exact location never leaks through image metadata.
- Photo picker and reorder in `CreateListingPage`, gallery in `HomeDetailPage`, cover image in `HomeCard`. `CachedAsyncImage` already exists for display.
- Delete Storage objects in the `onHomeDeleted` and `onUserDeleted` cascades.
- Update the README, which currently says photos are "scaffolded but not shipped."

### 2. Lock photos to friends
Once photos ship, the "unguessable URL" model is the weakest link in the friends-only promise. Options in order of effort:
- **Short-lived signed URLs from a callable.** A `listingPhotoURLs` callable checks the caller against the listing's `allowedViewerIDs` (the same check `firestore.rules` does) and returns signed URLs that expire in minutes. Storage `get` is then closed to clients entirely.
- An image proxy function, if signed URLs turn out to be awkward with the image cache.

### 3. Turn on App Check enforcement for Firestore and Storage
Callables already use `enforceAppCheck: true`, but the comment at `functions/src/index.ts` (around `requireFullMember`) notes that Firestore-side enforcement is a console setting that lives outside the repo. `firestore.rules` names App Check as its primary defence against hand-rolled clients in two places, so this should be on before launch. Add a short checklist in the README so it isn't lost.

### 4. Image moderation
Keyword moderation for messages and listings exists (`functions/src/moderation.ts`), but image moderation is deferred because it needs Cloud Vision. With photos shipping, add a Storage `onObjectFinalized` trigger that runs SafeSearch and files a report into the existing `reports` queue (same "report, don't silently delete" philosophy as text moderation).

---

## Next: depth and quality

### 5. Split the two largest files
`firestore.rules` (about 1,450 lines) and `functions/src/index.ts` (about 1,430 lines) are the riskiest places to make changes. Split functions into modules by domain (`stays.ts`, `friends.ts`, `messaging.ts`, `account.ts`) re-exported from `index.ts`. For rules, group helper functions at the top and keep each collection's block self-contained. No behaviour change; the existing rules tests are the safety net.

### 6. Cloud Functions tests
CI builds and lints functions but does not test them. The stay lifecycle (`acceptStayRequest`, `onStayRequestWritten`, `expireCompletedStays`) and the deletion cascade are the highest-stakes logic in the backend. Add emulator-backed tests with `firebase-functions-test`, starting with accept-request races and the account-deletion cascade, and run them in the existing `rules-tests` CI job.

### 7. Identity verification
`TrustStats.idVerified` exists and renders "not verified," but nothing sets it. For a trust-first product, a lightweight path helps hosts say yes: start with verified phone number via Firebase Auth phone linking, and consider a third-party ID check later.

### 8. Server-side emergency contact
`EmergencyContact` deliberately shares via the guest's own share sheet. An opt-in "notify my contact when I check in and out" (SMS or email from a function) would make the safety check-in meaningful when the guest forgets. Needs a provider (for example Twilio or SendGrid) and a privacy policy update.

### 9. Accessibility pass
Only about 47 `accessibilityLabel` uses exist across the app, and there is one UI test. Audit VoiceOver on the main flows (feed, listing detail, request sheet, messaging, availability calendar), check Dynamic Type at the largest sizes, and add UI tests for request-and-accept so regressions show up in CI.

### 10. Localization groundwork
There is no string catalog yet. Move user-facing strings into a `Localizable.xcstrings` now, while the app is small. Translations can come later; the extraction is the expensive part and gets more expensive with every feature.

---

## Later: growth and reach

### 11. Invite and onboarding loop
The app only works if your friends are on it. Universal-link invites exist (`DeepLinkRouter`, `admin/i/`). Measure the funnel (add `inviteSent` and `inviteAccepted` to `Telemetry.Event`) and iterate on the empty-feed experience for a new user with zero friends, which is the moment most likely to lose someone.

### 12. Calendar sync
Hosts already manage availability in-app, and `CalendarInvite` exports single stays. An iCal feed per listing (and import of a host's personal calendar to block dates) removes double-entry for hosts.

### 13. Supabase spike (only if Firebase limits bite)
Time-box one week. Scope: Supabase Storage for listing photos with an RLS policy that joins against a mirrored friend table, authenticated with Firebase Auth tokens via Supabase third-party auth. Outcome is a written go/no-go on a full migration, judged on policy clarity, cost and latency against item 2.

### 14. Android or web client
The friend graph makes cross-platform reach matter: a friend on Android cannot see your listing. A read-mostly web client (browse friends' listings, request a stay, message) on the existing Firebase backend is the cheaper first step, and `admin/` already shows the hosting setup.

---

## Suggested order

| # | Item | Size | Why first |
|---|------|------|-----------|
| 1 | Ship listing photos | M | Biggest product gap; seams already built |
| 3 | App Check enforcement | S | Console change plus docs; protects the rules |
| 2 | Lock photos to friends | M | Keeps the friends-only promise once photos exist |
| 4 | Image moderation | S | Needed the day photos go live |
| 6 | Functions tests | M | Protects the stay lifecycle before more features land |
| 5 | Split large files | M | Makes everything after it cheaper |
| 7–10 | Trust, safety, accessibility, localization | M each | Launch quality |
| 11–14 | Growth and reach | L | After real users |

## Open questions

- **The four agreed Firebase next steps.** Earlier sessions agreed four Firebase next steps that are not written down in the repo (the internal `docs/internal/TODO.md` is gitignored). This roadmap assumes they overlap with items 1 to 4 above. If they differ, they should replace or reorder those items.
- **GitHub issues.** The repository has no open or closed issues, so nothing here comes from the issue tracker. Each item above could become an issue to track progress.
