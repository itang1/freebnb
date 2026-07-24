// The same values live in more than one language on purpose: firestore.rules,
// the Swift app, the Cloud Functions, the admin console, and the seed scripts
// cannot share code, so caps, enum whitelists, and id formats are written out
// in each. A change to one copy and not the others is a silent bug (the
// 'offered'/'modified' event kinds shipped in the client while the rules still
// whitelisted four, and the courtesy notes just never arrived).
//
// This file is the tripwire: it parses each copy out of the real source files
// and asserts they still agree. Pure text checks, no emulator needed, so it
// also runs standalone: `node --test mirrors.test.mjs`.
//
// If a test here fails, the fix is almost never in this file. Find the copies
// it names, decide which one is right, and move the others to match.

import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { describe, it } from "node:test";
import { number, quoted, read, section, swiftEnumCases, swiftStayEventKinds } from "./sources.mjs";

const require = createRequire(import.meta.url);
const { MAX_TERMS, MAX_PREFIX_LENGTH } = require("../scripts/search_terms.js");

const rules = read("firestore.rules");
const indexTs = read("functions/src/index.ts");
const pathsTs = read("functions/src/paths.ts");
const adminApp = read("admin/app.js");
const seed = read("scripts/seed_test_data.js");

const messageStore = read("freebnb/Shared/MessageStore.swift");
const messagesRepository = read("freebnb/Shared/MessagesRepository.swift");
const userProfileRepository = read("freebnb/Shared/UserProfileRepository.swift");
const firestorePathsSwift = read("freebnb/Shared/FirestorePaths.swift");
const notificationPreferences = read("freebnb/Shared/NotificationPreferences.swift");
const homeSwift = read("freebnb/Homes/Home.swift");
const createListingViewModel = read("freebnb/Homes/CreateListingViewModel.swift");
const stayRequestSwift = read("freebnb/Stays/StayRequest.swift");
const reviewSwift = read("freebnb/Trust/Review.swift");
const reportSheet = read("freebnb/Safety/ReportSheet.swift");
const inviteCopy = read("freebnb/Shared/InviteCopy.swift");
const entitlements = read("freebnb/freebnb.entitlements");
const firebaseJson = JSON.parse(read("firebase.json"));
const aasa = JSON.parse(read("admin/well-known/apple-app-site-association.json"));

function sameSet(actual, expected, message) {
  assert.deepEqual([...actual].sort(), [...expected].sort(), message);
}

describe("stay event kinds", () => {
  it("rules validMessageEvent whitelists exactly the Swift StayEvent.Kind set", () => {
    const rulesKinds = quoted(
      section(rules, "data.event.kind in [", "]", "validMessageEvent kinds")
    );
    sameSet(
      rulesKinds,
      swiftStayEventKinds(),
      "firestore.rules validMessageEvent vs StayEvent.Kind in MessageStore.swift"
    );
  });
});

describe("message rate limit", () => {
  const windowSeconds = number(rules, /function windowSeconds\(\) \{ return (\d+); \}/, "rules windowSeconds");
  const messageCap = number(rules, /function messageCap\(\) \{ return (\d+); \}/, "rules messageCap");

  it("the client's advisory pre-check matches the rules", () => {
    assert.equal(
      number(messageStore, /private let sendRateLimit = (\d+)/, "MessageStore.sendRateLimit"),
      messageCap,
      "MessageStore.sendRateLimit vs rules messageCap()"
    );
    assert.equal(
      number(messageStore, /sendRateWindow: TimeInterval = (\d+)/, "MessageStore.sendRateWindow"),
      windowSeconds,
      "MessageStore.sendRateWindow vs rules windowSeconds()"
    );
  });

  it("the repository's window check matches the rules", () => {
    assert.equal(
      number(messagesRepository, /rateWindow: TimeInterval = (\d+)/, "MessagesRepository.rateWindow"),
      windowSeconds,
      "FirestoreMessagesRepository.rateWindow vs rules windowSeconds()"
    );
  });
});

describe("listing caps", () => {
  it("title cap: CreateListingViewModel vs rules, on both documents that carry it", () => {
    const swiftCap = number(createListingViewModel, /static let titleMaxLength = (\d+)/, "titleMaxLength");
    assert.equal(
      number(rules, /isOptionalString\(data, 'title', (\d+)\)/, "rules title cap"),
      swiftCap,
      "homes title cap vs CreateListingViewModel.titleMaxLength"
    );
    assert.equal(
      number(rules, /'listingTitle', (\d+)\)/, "rules listingTitle cap"),
      swiftCap,
      "stayRequests listingTitle snapshot cap vs CreateListingViewModel.titleMaxLength"
    );
  });

  it("co-host cap: Home.maxCoHosts vs rules", () => {
    assert.equal(
      number(rules, /'coHostUserIDs', (\d+)\)/, "rules coHostUserIDs cap"),
      number(homeSwift, /static let maxCoHosts = (\d+)/, "Home.maxCoHosts")
    );
  });

  it("booked-ranges cap: functions BOOKED_RANGES_CAP vs rules", () => {
    assert.equal(
      number(rules, /'bookedDateRanges', (\d+)\)/, "rules bookedDateRanges cap"),
      number(indexTs, /const BOOKED_RANGES_CAP = (\d+)/, "BOOKED_RANGES_CAP")
    );
  });

  it("viewer ACL cap: functions ACL_CAP vs rules", () => {
    assert.equal(
      number(rules, /'allowedViewerIDs', (\d+)\)/, "rules allowedViewerIDs cap"),
      number(indexTs, /const ACL_CAP = (\d+)/, "ACL_CAP")
    );
  });

  it("hostNote cap: every rules occurrence and the acceptStayRequest re-check agree", () => {
    const rulesCaps = [...rules.matchAll(/'hostNote', (\d+)\)/g)].map((m) => Number(m[1]));
    assert.ok(rulesCaps.length > 0, "no hostNote caps found in rules");
    const callableCap = number(indexTs, /hostNote\.length > (\d+)/, "acceptStayRequest hostNote cap");
    for (const cap of rulesCaps) {
      assert.equal(cap, callableCap, "rules hostNote cap vs acceptStayRequest re-check");
    }
  });
});

describe("notification categories", () => {
  it("Swift NotificationCategory cases match the functions' union type", () => {
    // A renamed Swift case moves the stored preference under a new key; the
    // server reads the old key, finds nothing, and treats the category as
    // opted-in, so a muted category silently starts pushing again.
    const swiftCases = swiftEnumCases(
      section(notificationPreferences, "enum NotificationCategory", "var id", "NotificationCategory")
    );
    const tsUnion = quoted(section(indexTs, "type NotificationCategory =", ";", "TS NotificationCategory"));
    sameSet(swiftCases, tsUnion, "NotificationPreferences.swift vs functions/src/index.ts");
  });
});

describe("stay request enums", () => {
  it("every Swift status raw value appears in both the rules and the functions", () => {
    const statuses = swiftEnumCases(
      section(stayRequestSwift, "enum StayRequestStatus", "var displayName", "StayRequestStatus")
    );
    assert.ok(statuses.length >= 6, `expected the six stay statuses, parsed: ${statuses}`);
    for (const status of statuses) {
      assert.ok(rules.includes(`"${status}"`), `status "${status}" missing from firestore.rules`);
      assert.ok(indexTs.includes(`"${status}"`), `status "${status}" missing from functions/src/index.ts`);
    }
  });

  it("arrival windows: Swift enum vs rules whitelist", () => {
    const swiftWindows = swiftEnumCases(
      section(stayRequestSwift, "enum ArrivalWindow", "var displayName", "ArrivalWindow")
    );
    const rulesWindows = quoted(
      section(rules, "request.resource.data.arrivalWindow in", "]", "rules arrivalWindow")
    );
    sameSet(swiftWindows, rulesWindows, "ArrivalWindow vs rules arrivalWindow whitelist");
  });
});

describe("reports", () => {
  it("triage statuses: admin console vs rules", () => {
    const adminStatuses = quoted(section(adminApp, "const STATUSES = [", "]", "admin STATUSES"));
    const reportsBlock = rules.slice(rules.indexOf("match /reports/"));
    const rulesStatuses = quoted(section(reportsBlock, "request.resource.data.status in [", "]", "rules triage statuses"));
    sameSet(adminStatuses, rulesStatuses, "admin/app.js STATUSES vs rules triage whitelist");
  });

  it("target types: Swift sheet vs rules vs functions", () => {
    const swiftTargets = swiftEnumCases(section(reportSheet, "enum TargetType", "\n    }", "TargetType"));
    const rulesTargets = quoted(section(rules, "request.resource.data.targetType in [", "]", "rules targetType"));
    const tsTargets = quoted(section(indexTs, 'targetType: "', ";", "fileAutoReport targetType"));
    sameSet(swiftTargets, rulesTargets, "ReportSheet.TargetType vs rules");
    sameSet(swiftTargets, tsTargets, "ReportSheet.TargetType vs fileAutoReport's union");
  });
});

describe("search terms", () => {
  it("caps: scripts/search_terms.js vs Swift vs rules", () => {
    assert.equal(
      number(userProfileRepository, /static let maxTerms = (\d+)/, "UserSearchTerms.maxTerms"),
      MAX_TERMS,
      "Swift maxTerms vs search_terms.js MAX_TERMS"
    );
    assert.equal(
      number(userProfileRepository, /static let maxPrefixLength = (\d+)/, "UserSearchTerms.maxPrefixLength"),
      MAX_PREFIX_LENGTH,
      "Swift maxPrefixLength vs search_terms.js MAX_PREFIX_LENGTH"
    );
    assert.equal(
      number(rules, /searchTerms\.size\(\) <= (\d+)/, "rules searchTerms cap"),
      MAX_TERMS,
      "rules searchTerms cap vs search_terms.js MAX_TERMS"
    );
  });
});

describe("firestore paths", () => {
  it("every name the functions use exists in FirestorePaths.swift", () => {
    const swiftNames = new Set(quoted(section(firestorePathsSwift, "enum FirestorePaths", "\n}", "FirestorePaths")));
    const tsNames = [
      ...quoted(section(pathsTs, "export const Collections", "} as const", "Collections")),
      ...quoted(section(pathsTs, "export const Subcollections", "} as const", "Subcollections")),
      ...quoted(section(pathsTs, "export const Docs", "} as const", "Docs")),
    ];
    for (const name of tsNames) {
      assert.ok(swiftNames.has(name), `paths.ts name "${name}" missing from FirestorePaths.swift`);
    }
  });

  it("every collection the functions use has a match block in the rules", () => {
    for (const name of quoted(section(pathsTs, "export const Collections", "} as const", "Collections"))) {
      assert.ok(rules.includes(`match /${name}/`), `no rules match block for /${name}/`);
    }
  });
});

describe("derived id formats", () => {
  it("conversation ids join sorted participants with '_' on both sides", () => {
    assert.match(messageStore, /userIDs\.sorted\(\)\.joined\(separator: "_"\)/, "MessageStore.conversationID");
    assert.match(indexTs, /\[\.\.\.msg\.participants\]\.sort\(\)/, "onMessageCreated sorts participants");
    assert.match(indexTs, /participants\.join\("_"\)/, "onMessageCreated joins with '_'");
  });

  it("friend edge ids are the sorted pair joined with '_' on both sides", () => {
    const friendStore = read("freebnb/Friends/FriendStore.swift");
    assert.match(friendStore, /\[a, b\]\.sorted\(\)\.joined\(separator: "_"\)/, "FriendEdge.edgeID");
    assert.match(
      rules,
      /edgeID == request\.resource\.data\.userA \+ "_" \+ request\.resource\.data\.userB/,
      "rules canonical edge id"
    );
  });

  it("review ids are stayRequestID_authorUserID on both sides", () => {
    assert.match(reviewSwift, /\\\(stayRequestID\)_\\\(authorUserID\)/, "Review id in Swift");
    assert.match(
      rules,
      /reviewID == request\.resource\.data\.stayRequestID \+ '_' \+ request\.auth\.uid/,
      "rules review id"
    );
  });
});

describe("public coordinate rounding", () => {
  it("the seed blurs coordinates to the same precision as Home.approximate", () => {
    const precision = number(
      homeSwift,
      /static let publicCoordinatePrecision = (\d+(?:\.\d+)?)/,
      "Home.publicCoordinatePrecision"
    );
    const factorMatch = seed.match(/Math\.round\(value \* (\d+)\) \/ (\d+)/);
    assert.ok(factorMatch, "seed_test_data.js approximate() rounding not found");
    assert.equal(factorMatch[1], factorMatch[2], "seed approximate() multiplies and divides by the same factor");
    assert.equal(Number(factorMatch[1]), 10 ** precision, "seed rounding factor vs Home.publicCoordinatePrecision");
  });
});

// The invite link is the only bridge into a friends-only app, and the pieces
// that make it open the app instead of Safari live in four files that cannot
// import each other: the Swift that builds the link, the entitlement that
// claims the domain, the AASA file iOS fetches to check that claim, and the
// hosting config that serves it. Nothing fails loudly when they disagree —
// links simply keep opening the browser — so they are checked here.
describe("invite universal link", () => {
  const swiftString = (name) => {
    const match = inviteCopy.match(new RegExp(`static let ${name} = "([^"]+)"`));
    assert.ok(match, `InviteCopy.${name} not found`);
    return match[1];
  };

  const webHost = swiftString("webHost");
  const webPath = swiftString("webPath");
  const detail = aasa.applinks.details[0];

  it("the entitlement claims the host InviteCopy builds links for", () => {
    assert.ok(
      entitlements.includes(`<string>applinks:${webHost}</string>`),
      `freebnb.entitlements does not claim applinks:${webHost}`
    );
  });

  it("the AASA covers the path InviteCopy builds, and names this app", () => {
    const paths = detail.components.map((c) => c["/"]);
    assert.ok(paths.includes(webPath), `AASA components do not cover ${webPath}`);
    for (const appID of detail.appIDs) {
      assert.ok(
        appID.endsWith(".com.poodlestrategy.freebnb"),
        `AASA appID ${appID} is not this app's bundle id`
      );
    }
  });

  it("hosting serves the AASA from the well-known path, as JSON", () => {
    const wellKnown = "/.well-known/apple-app-site-association";
    const rewrite = firebaseJson.hosting.rewrites.find((r) => r.source === wellKnown);
    assert.ok(rewrite, `firebase.json has no rewrite for ${wellKnown}`);
    // Served from a path without a leading dot, because hosting's ignore of
    // "**/.*" would drop the file from the deploy without saying so.
    assert.equal(rewrite.destination, "/well-known/apple-app-site-association.json");
    assert.ok(
      !firebaseJson.hosting.ignore.some((pattern) => rewrite.destination.includes(pattern.replace("**/", ""))),
      "the AASA destination is covered by an ignore pattern"
    );

    const header = firebaseJson.hosting.headers.find((h) => h.source === wellKnown);
    assert.ok(header, `firebase.json sets no headers for ${wellKnown}`);
    assert.deepEqual(
      header.headers.find((h) => h.key === "Content-Type")?.value,
      "application/json",
      "Apple requires the AASA to be served as application/json"
    );
  });

  it("hosting serves the landing page at the invite path", () => {
    const rewrite = firebaseJson.hosting.rewrites.find((r) => r.source === webPath);
    assert.ok(rewrite, `firebase.json has no rewrite for ${webPath}`);
    assert.equal(rewrite.destination, `${webPath}/index.html`);
  });

  it("the landing page hands the sender to the app's own scheme", () => {
    const landing = read(`admin${webPath}/index.html`);
    const scheme = swiftString("customScheme");
    const queryItem = inviteCopy.match(/static let inviterQueryItem = "([^"]+)"/)[1];
    assert.ok(
      landing.includes(`"${scheme}://invite"`),
      `the landing page does not fall back to ${scheme}://invite`
    );
    assert.ok(
      landing.includes(`get("${queryItem}")`),
      `the landing page does not read the ?${queryItem}= parameter`
    );
  });
});
