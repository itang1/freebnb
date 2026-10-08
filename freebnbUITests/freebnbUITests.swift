//
//  freebnbUITests.swift
//  freebnbUITests
//
//  Every test launches with `-UseFirebaseEmulator`, so writes hit the local emulators
//  (Auth :9099, Firestore :8080), never production. `-UITesting` signs out and resets
//  the age-gate/onboarding flags for a known state. The DEBUG-only sign-in buttons
//  need the emulator (see AuthManager.signInWithEmail).
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

    /// Accepts the 18+ gate; no-op if it isn't showing. The timeout is generous
    /// because a slow launch would otherwise leave the gate covering WelcomePage.
    private func passAgeGate(_ app: XCUIApplication) {
        let continueButton = app.buttons["ageGate.continueButton"]
        if continueButton.waitForExistence(timeout: 30) {
            continueButton.tap()
        }
    }

    /// Taps once the element exists; tapping before layout is a silent no-op that surfaces later as "not found".
    @discardableResult
    private func waitAndTap(_ element: XCUIElement, timeout: TimeInterval = 15) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Timed out waiting for \(element)")
            return false
        }
        element.tap()
        return true
    }

    /// Taps a field and types, re-tapping once if focus didn't take (the biggest
    /// flake source). Clears first, because `typeText` appends and a pre-populated
    /// form silently produced concatenated values the assertions never checked.
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

    /// Dismisses the onboarding sheet after sign-in, which `-UITesting` re-shows and which covers the tab bar. No-op if absent.
    private func dismissOnboarding(_ app: XCUIApplication) {
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 15) {
            skip.tap()
        }
    }

    /// Signs into the DEBUG guest@freebnb.test account from WelcomePage.
    private func signInAsGuest(_ app: XCUIApplication) {
        passAgeGate(app)
        waitAndTap(app.buttons["welcome.guestSignInButton"])
    }

    /// Signs into the DEBUG dev@freebnb.test account, from WelcomePage or the Profile tab's "Dev" section.
    private func signInAsDev(_ app: XCUIApplication) {
        // The gate comes first: it covers WelcomePage, so probing underneath always times out.
        passAgeGate(app)
        if app.buttons["welcome.devnaSignInButton"].waitForExistence(timeout: 3) {
            waitAndTap(app.buttons["welcome.devnaSignInButton"])
            dismissOnboarding(app)
            // Sign-in lands on Listings; the email lives on Profile.
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
        // The pane switcher's pill, not the Listings tab, which a bare "Listings" now matches.
        waitAndTap(app.buttons["My Listings"])
        waitAndTap(app.buttons["Create listing"])

        focusAndType("1 Infinite Loop", into: app.textFields["Street"])
        focusAndType("Cupertino", into: app.textFields["City"])
        focusAndType("CA", into: app.textFields["State"])
        focusAndType("95014", into: app.textFields["ZIP"])

        // canSave() needs a sleeping surface; match the bed stepper by label (the first stepper is "Guest rooms").
        let bedStepper = app.steppers
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "bed")).firstMatch
        // Scroll it into view: Form renders rows lazily and the keyboard covers the rest, so waiting on it only waits for nothing.
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

        // Saving dismisses back to the Stays pane, titled "My Listings" (the default only holds when Profile pushes it).
        XCTAssertTrue(app.navigationBars["My Listings"].waitForExistence(timeout: 10))
    }

    // MARK: - Request a stay + message the host
    //
    // Drives the dev account as the guest against a seeded host's listing. Dev is an
    // accepted friend of the whole cast. Accept/decline needs a second session and is
    // covered at the StayRequestStore level in freebnbTests.

    @MainActor
    func testRequestStayAndSendMessage() throws {
        let app = launchApp()
        signInAsDev(app)

        waitAndTap(app.tabBars.buttons["Listings"])

        // It must be someone else's listing, since HomeDetailPage drops the contact
        // section for the host. The feed's first row is the dev-owned listing that
        // testCreateListingFlow leaves on top, so name a seeded host.
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
            // A host with several places gets a "which place?" dialog first; take the first.
            let listingChoice = app.sheets.firstMatch
            if listingChoice.waitForExistence(timeout: 3) {
                listingChoice.buttons.element(boundBy: 0).tap()
            }
            // Send stays disabled until the grid holds a whole stay: pick the first
            // available day, which re-labels it, so firstMatch resolves to the next.
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
    // ChoiceSection exposes its selected option only via the `.isSelected` trait; this
    // taps the cancellation-policy section and asserts the trait follows the tap.

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
        // The pane switcher's pill, not the Listings tab, which a bare "Listings" now matches.
        waitAndTap(app.buttons["My Listings"])
        waitAndTap(app.buttons["Create listing"])

        XCTAssertTrue(app.textFields["Street"].waitForExistence(timeout: 10))

        // Each option is one element labelled "<name>, <detail>" and carries .isSelected;
        // the trailing comma avoids matching the option's separate name text.
        let moderate = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Moderate,")).firstMatch
        let strict = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Strict,")).firstMatch

        // The section sits below the address and sleeping fields; scroll it into the accessibility tree.
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
