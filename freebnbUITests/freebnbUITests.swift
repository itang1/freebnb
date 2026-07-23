//
//  freebnbUITests.swift
//  freebnbUITests
//
//  Every test launches with `-UseFirebaseEmulator` so it talks to a local
//  `firebase emulators:start` (Auth on :9099, Firestore on :8080) instead of
//  the production project — writes here never touch real data. `-UITesting`
//  makes the app sign out and reset the age-gate/onboarding flags on launch so
//  each test starts from a known state. The DEBUG-only "Sign in as guest" /
//  "Sign in as devna" buttons on WelcomePage require the emulator (see
//  AuthManager.signInWithEmail), so every test here needs it too.
//

import XCTest

final class freebnbUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITesting", "-UseFirebaseEmulator"]
        app.launch()
        return app
    }

    /// Accepts the 18+ gate. No-op if it isn't showing.
    ///
    /// The timeout is generous because the gate is behind the app's Firebase
    /// setup: a launch slower than the wait left the gate to appear afterwards,
    /// covering WelcomePage for the rest of the test.
    private func passAgeGate(_ app: XCUIApplication) {
        let continueButton = app.buttons["ageGate.continueButton"]
        if continueButton.waitForExistence(timeout: 30) {
            continueButton.tap()
        }
    }

    /// Taps once the element exists. Tapping an element that hasn't been laid out
    /// yet is silently a no-op, which shows up later as a confusing "not found"
    /// on whatever the tap was supposed to reveal.
    @discardableResult
    private func waitAndTap(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Timed out waiting for \(element)")
            return false
        }
        element.tap()
        return true
    }

    /// Taps a field and types, re-tapping once if the first tap didn't take
    /// focus — simulators drop the first tap's focus often enough (hardware
    /// keyboard attach, in-flight scroll) that typing straight away is the
    /// single biggest source of flakes in this suite.
    /// Clears first, because `typeText` appends. A form that arrives already
    /// populated — a re-run against a live emulator, a draft the sheet restored,
    /// a step that ran twice — silently produced concatenated values instead of
    /// the ones written here, and the test still passed: "Cupertino" typed into a
    /// field holding "Pasadena Heights" is a listing in "Pasadena HeightsCupertino"
    /// that no assertion here looks at. Every address in the emulator that reads
    /// like two strings run together was written this way.
    private func focusAndType(_ text: String, into field: XCUIElement) {
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        if (field.value(forKey: "hasKeyboardFocus") as? Bool) != true {
            field.tap()
        }
        if let existing = field.value as? String, !existing.isEmpty,
           existing != (field.placeholderValue ?? "") {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(text)
    }

    /// Dismisses the onboarding sheet that follows a sign-in. `-UITesting` clears
    /// `hasSeenOnboarding` on every launch, so it always shows, and it covers the
    /// tab bar: taps land on nothing until it's gone. No-op if it isn't showing.
    private func dismissOnboarding(_ app: XCUIApplication) {
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 15) {
            skip.tap()
        }
    }

    /// Signs into the `#if DEBUG`-only guest@freebnb.test account directly from
    /// WelcomePage (see AuthManager.signInWithEmail).
    private func signInAsGuest(_ app: XCUIApplication) {
        passAgeGate(app)
        waitAndTap(app.buttons["welcome.guestSignInButton"])
    }

    /// Signs into the `#if DEBUG`-only dev@freebnb.test account (see
    /// AuthManager.signInWithEmail). Works from WelcomePage or, once already
    /// signed in, from the Profile tab's "Dev" section.
    private func signInAsDev(_ app: XCUIApplication) {
        // The gate has to come first: it covers WelcomePage, so probing for the
        // button underneath it always times out and sends us down the
        // already-signed-in branch. No-op when the gate isn't showing.
        passAgeGate(app)
        if app.buttons["welcome.devnaSignInButton"].waitForExistence(timeout: 3) {
            waitAndTap(app.buttons["welcome.devnaSignInButton"])
            dismissOnboarding(app)
            // Signing in from the welcome screen lands on Listings; the email
            // (and everything callers reach for next) lives on Profile.
            waitAndTap(app.tabBars.buttons["Profile"])
        } else {
            waitAndTap(app.tabBars.buttons["Profile"])
            waitAndTap(app.buttons["profile.devSignInButton"])
        }
        XCTAssertTrue(app.staticTexts["dev@freebnb.test"].waitForExistence(timeout: 15))
    }

    // MARK: - Sign in

    @MainActor
    func testGuestSignInReachesListings() throws {
        let app = launchApp()
        signInAsGuest(app)
        XCTAssertTrue(app.tabBars.buttons["Listings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Stays"].exists)
        XCTAssertTrue(app.tabBars.buttons["Messages"].exists)
    }

    @MainActor
    func testDevSignInShowsAccountEmail() throws {
        let app = launchApp()
        signInAsDev(app)
    }

    // MARK: - Create listing

    @MainActor
    func testCreateListingFlow() throws {
        let app = launchApp()
        signInAsDev(app)

        // A listing requires a display name; set one if this is a fresh emulator user.
        if app.buttons["Edit Name"].waitForExistence(timeout: 5) {
            app.buttons["Edit Name"].tap()
            let nameField = app.textFields["Name"]
            if nameField.waitForExistence(timeout: 5), (nameField.value as? String)?.isEmpty != false {
                nameField.tap()
                nameField.typeText("Dev Host")
                app.buttons["Save"].tap()
            } else {
                app.buttons["Cancel"].tap()
            }
        }

        waitAndTap(app.tabBars.buttons["Stays"])
        // The pane switcher's pill, not the Listings tab: both are buttons, and a
        // bare "Listings" now matches the tab item instead.
        waitAndTap(app.buttons["My Listings"])
        waitAndTap(app.buttons["Create listing"])

        focusAndType("1 Infinite Loop", into: app.textFields["Street"])
        focusAndType("Cupertino", into: app.textFields["City"])
        focusAndType("CA", into: app.textFields["State"])
        focusAndType("95014", into: app.textFields["ZIP"])

        // Sleeping arrangements: canSave() needs a sleeping surface, and only
        // these steppers populate sleepingCounts. Match the bed one by label —
        // the form's first stepper is "Guest rooms", which doesn't count.
        let bedStepper = app.steppers
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "bed")).firstMatch
        // Scroll it into view first. The sleeping steppers sit below the fold, a
        // Form renders its rows lazily, and the address fields above just raised
        // the keyboard over what little was left — so the row genuinely does not
        // exist yet, and waiting ten seconds for it only waits for nothing.
        var stepperScrolls = 0
        while !bedStepper.exists && stepperScrolls < 6 {
            app.swipeUp()
            stepperScrolls += 1
        }
        XCTAssertTrue(bedStepper.waitForExistence(timeout: 10), "sleeping steppers never came into view")
        bedStepper.buttons.element(boundBy: 1).tap()

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        // Saving dismisses the sheet, back to the Stays pane it was opened from.
        // That one titles itself "My Listings"; "Your Listings" is the default
        // this page only keeps when Profile pushes it.
        XCTAssertTrue(app.navigationBars["My Listings"].waitForExistence(timeout: 10))
    }

    // MARK: - Request a stay + message the host
    //
    // Drives the dev account as the guest against a seeded host's listing. The
    // dev account is seeded as an accepted friend of the whole cast, so those
    // listings are visible to it and messageable. Accept/decline (which needs a
    // second signed-in session) is covered by StayRequestStore-level tests
    // instead — see freebnbTests.

    @MainActor
    func testRequestStayAndSendMessage() throws {
        let app = launchApp()
        signInAsDev(app)

        waitAndTap(app.tabBars.buttons["Listings"])

        // It has to be someone else's listing: HomeDetailPage drops the whole
        // contact section when you're the host, so the message button never
        // appears on your own. Taking the feed's first row picked exactly that —
        // the feed is newest-first and testCreateListingFlow leaves a fresh
        // dev-owned listing on top — which is why this test spent its life
        // skipping itself instead of covering anything. Name a seeded host.
        let host = "SpongeBob SquarePants"
        let listing = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", host)).firstMatch
        var scrolls = 0
        while !listing.exists && scrolls < 10 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(listing.waitForExistence(timeout: 10), "\(host)'s seeded listing never appeared in the feed")
        listing.tap()

        let messageButton = app.buttons["homeDetail.messageHostButton"]
        XCTAssertTrue(messageButton.waitForExistence(timeout: 10))
        messageButton.tap()

        if app.buttons["Request a Stay"].waitForExistence(timeout: 5) {
            app.buttons["Request a Stay"].tap()
            // A host with more than one visible place gets a "which place?"
            // dialog before the sheet; the seeded SpongeBob has two. Take the
            // first.
            let listingChoice = app.sheets.firstMatch
            if listingChoice.waitForExistence(timeout: 3) {
                listingChoice.buttons.element(boundBy: 0).tap()
            }
            // Send stays disabled until the sheet's grid holds a whole stay, so
            // pick one night: the first available day, then the next. Tapping
            // the first re-labels it "selected as check in", which conveniently
            // makes firstMatch resolve to the following available day.
            let availableDay = app.buttons.matching(
                NSPredicate(format: "label ENDSWITH %@", ", available")
            ).firstMatch
            XCTAssertTrue(availableDay.waitForExistence(timeout: 10), "No available day to tap in the stay grid")
            availableDay.tap()
            availableDay.tap()
            waitAndTap(app.buttons["Send"])
        }

        let draft = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Message ")).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("Looking forward to it!")
        app.buttons["Send message"].tap()

        XCTAssertTrue(app.staticTexts["Looking forward to it!"].waitForExistence(timeout: 10))
    }

    // MARK: - ChoiceSection selection
    //
    // ChoiceSection (the create-listing form's radio-style sections) exposes its
    // selected option only through the `.isSelected` accessibility trait. This
    // taps through the cancellation-policy section and asserts the trait follows
    // the tapped option rather than sticking to the default.

    @MainActor
    func testChoiceSectionSelectionMovesTrait() throws {
        let app = launchApp()
        signInAsDev(app)

        // A listing requires a display name; set one if this is a fresh emulator user.
        if app.buttons["Edit Name"].waitForExistence(timeout: 5) {
            app.buttons["Edit Name"].tap()
            let nameField = app.textFields["Name"]
            if nameField.waitForExistence(timeout: 5), (nameField.value as? String)?.isEmpty != false {
                nameField.tap()
                nameField.typeText("Dev Host")
                app.buttons["Save"].tap()
            } else {
                app.buttons["Cancel"].tap()
            }
        }

        waitAndTap(app.tabBars.buttons["Stays"])
        // The pane switcher's pill, not the Listings tab: both are buttons, and a
        // bare "Listings" now matches the tab item instead.
        waitAndTap(app.buttons["My Listings"])
        waitAndTap(app.buttons["Create listing"])

        XCTAssertTrue(app.textFields["Street"].waitForExistence(timeout: 10))

        // ChoiceSection combines each option into one element whose label reads
        // "<name>, <detail>" — a static text, and the one carrying .isSelected.
        // The trailing comma matters: the option's own name survives as a
        // separate static text, so a bare "Moderate" matches that one instead.
        let moderate = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Moderate,")).firstMatch
        let strict = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Strict,")).firstMatch

        // The cancellation-policy section sits below the address and sleeping
        // fields, so scroll it into the accessibility tree first.
        var scrolls = 0
        while !moderate.exists && scrolls < 8 {
            app.swipeUp()
            scrolls += 1
        }
        XCTAssertTrue(moderate.waitForExistence(timeout: 5), "Cancellation-policy options never appeared")

        moderate.tap()
        XCTAssertTrue(moderate.isSelected, "Tapping Moderate should mark it selected")

        strict.tap()
        XCTAssertTrue(strict.isSelected, "Tapping Strict should move the selection to it")
        XCTAssertFalse(moderate.isSelected, "Selecting Strict should clear Moderate's selected trait")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
