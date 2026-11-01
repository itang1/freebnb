# Cloud Functions emulator tests

These exercise the functions' real Firestore behaviour (transactions, queries,
batched cascades) against the Firestore emulator. They complement
`rules-tests/`, which covers what *clients* may write; these cover what the
*server* does once a write lands.

## Running

Needs Java (the emulator is a Java process) and `firebase-tools`. From the repo
root:

```sh
npm ci --prefix functions
npm run build --prefix functions
firebase emulators:exec --only firestore --project freebnb-functions-tests \
  "cd functions && $(command -v node) --test test/*.test.js"
```

The tests load the compiled `lib/`, so rebuild after changing `src/`. Node is
invoked by absolute path for the same reason as in `rules-tests/README.md`.

`harness.js` refuses to start without `FIRESTORE_EMULATOR_HOST`, so a stray run
can never reach a real project.

## How they work

- `firebase-functions-test`'s `wrap` invokes each function directly. No Functions
  emulator runs, so triggers never fire on their own: a test that writes a stay
  request and wants `onStayRequestWritten` to react calls it itself.
- Callables are invoked below the HTTP layer, so `enforceAppCheck` is not
  exercised; `requireFullMember` is.
- Storage and FCM have no emulator here. `harness.js` swaps `admin.storage()` and
  `admin.messaging()` for recorders before `lib/index.js` loads; tests assert on
  `deletedStoragePrefixes` and `pushes`.
- Each file uses its own project id, so `node --test` can run the files in
  parallel without them sharing data. `reset()` clears that project between tests.

## What's covered

| File | Function |
| --- | --- |
| `acceptStayRequest.test.js` | Concurrent accepts (overlapping requests, and the same request twice), turnover buffer, authorization, deleted listings |
| `onUserDeleted.test.js` | The account-deletion cascade, counterparty trust-stat recompute, retry safety, >500-doc paging |
| `onStayRequestWritten.test.js` | Booked-date publishing and the lifecycle pushes |
| `expireCompletedStays.test.js` | The nightly address-withdrawal sweep |
