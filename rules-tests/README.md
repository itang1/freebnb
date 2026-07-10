# firestore.rules regression tests

Rules are the app's real authorization boundary, so they get tested against the
real rules engine in the Local Emulator Suite rather than mocked.

These run on plain Node with `@firebase/rules-unit-testing`, which drives the
Firestore emulator directly. No simulator and no Xcode, which is why they live
here rather than in `freebnbTests/`: the Swift emulator suite
(`FirestoreHomesRepositoryEmulatorTests`) covers rules *through the repository
layer*, and needs a booted app to do it. Anything that is purely a question of
"does this rule admit this write" belongs in this directory.

## Running

Needs Java (the emulator is a Java process) and `firebase-tools`. From the repo
root:

```sh
npm ci --prefix rules-tests
firebase emulators:exec --only firestore --project freebnb-rules-tests \
  "cd rules-tests && $(command -v node) --test"
```

`emulators:exec` boots the emulator, runs the command, and tears it down. Each
test file loads `../firestore.rules` into its own project namespace and clears
Firestore between cases, so the files are independent and order does not matter.

Node is invoked by absolute path on purpose. A standalone `firebase-tools` build
puts its own bundled Node ahead of yours on `PATH` for the duration of the
command, and that build cannot load ES modules — a bare `node --test` dies with
`ERR_REQUIRE_ESM`, and `npm test` dies reading `stdin`. `$(command -v node)`
resolves the real binary before `firebase` gets a chance to shadow it.

## Writing a test

Two things the `messages` rule needs that are easy to miss:

- A message create is gated on `rateCounterAdvanced`, so the write must be a
  batch that also advances `rateLimits/{senderUserID}`. A lone `setDoc` on
  `messages/{id}` is denied no matter what the blocking rules say.
- `authenticatedContext(uid)` signs in with `sign_in_provider: "custom"`, which
  clears the rules' `isFullMember()` gate. Use `unauthenticatedContext()` to
  test the signed-out path; there is no built-in way to fake `anonymous`.

Always pair a deny-case with an allow-case. A rule that denies everything
satisfies every negative test on its own.
