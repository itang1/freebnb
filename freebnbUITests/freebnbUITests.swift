//
//  freebnbUITests.swift
//  freebnbUITests
//
//  Every test launches with `-UseFirebaseEmulator` so it talks to a local
//  `firebase emulators:start` (Auth on :9099, Firestore on :8080) instead of
//  the production project — writes here never touch real data. `-UITesting`
//  makes the app sign out and reset the age-gate/onboarding flags on launch so
//  each test starts from a known state. Tests that only read (guest sign-in,
//  dev sign-in) are safe to run without the emulator too, since the app falls
//  back to production Auth for a real, already-seeded account.
//

import XCTest

final class freebnbUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(useEmulator: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-UITesting"]
        if useEmulator {
            app.launchArguments += ["-UseFirebaseEmulator"]
        }
        app.launch()
        return app
    }

    /// Accepts the 18+ gate. No-op if it isn't showing.
    private func passAgeGate(_ app: XCUIApplication) {
        let continueButton = app.buttons["ageGate.continueButton"]
        if continueButton.waitForExistence(timeout: 5) {
            continueButton.tap()
        }
    }

    private func continueAsGuest(_ app: XCUIApplication) {
        passAgeGate(app)
        let guestButton = app.buttons["welcome.continueAsGuestButton"]
        XCTAssertTrue(guestButton.waitForExistence(timeout: 10))
        guestButton.tap()
    }

    /// Signs into the `#if DEBUG`-only dev@freebnb.test account (see
    /// AuthManager.signInWithEmail, ProfilePage) from wherever the tab bar is showing.
    private func signInAsDev(_ app: XCUIApplication) {
        app.tabBars.buttons["Profile"].tap()
        let devRow = app.buttons["profile.devSignInButton"]
        XCTAssertTrue(devRow.waitForExistence(timeout: 10))
        devRow.tap()
        XCTAssertTrue(app.staticTexts["dev@freebnb.test"].waitForExistence(timeout: 10))
    }

    // MARK: - Sign in

    @MainActor
    func testGuestSignInReachesListings() throws {
        let app = launchApp(useEmulator: false)
        continueAsGuest(app)
        XCTAssertTrue(app.tabBars.buttons["Listings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Stays"].exists)
        XCTAssertTrue(app.tabBars.buttons["Messages"].exists)
    }

    @MainActor
    func testDevSignInShowsAccountEmail() throws {
        let app = launchApp(useEmulator: false)
        continueAsGuest(app)
        signInAsDev(app)
    }

    // MARK: - Create listing

    @MainActor
    func testCreateListingFlow() throws {
        let app = launchApp()
        continueAsGuest(app)
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

        app.tabBars.buttons["Stays"].tap()
        app.buttons["Listings"].tap()
        app.buttons["Create listing"].tap()

        let streetField = app.textFields["Street"]
        XCTAssertTrue(streetField.waitForExistence(timeout: 10))
        streetField.tap()
        streetField.typeText("1 Infinite Loop")
        app.textFields["City"].tap()
        app.textFields["City"].typeText("Cupertino")
        app.textFields["State"].tap()
        app.textFields["State"].typeText("CA")
        app.textFields["ZIP"].tap()
        app.textFields["ZIP"].typeText("95014")

        // Sleeping arrangements: bump the first stepper's "+" so canSave() passes.
        app.steppers.firstMatch.buttons.element(boundBy: 1).tap()

        let saveButton = app.buttons["Save"]
        XCTAssertTrue(saveButton.isEnabled)
        saveButton.tap()

        XCTAssertTrue(app.navigationBars["Your Listings"].waitForExistence(timeout: 10))
    }

    // MARK: - Request a stay + message the host
    //
    // Uses the dev account as both host and guest against a listing it just
    // created, since a single UI test only drives one signed-in session.
    // Accept/decline (which needs a second account) is covered by
    // StayRequestStore-level tests instead — see freebnbTests.

    @MainActor
    func testRequestStayAndSendMessage() throws {
        let app = launchApp()
        continueAsGuest(app)
        signInAsDev(app)

        app.tabBars.buttons["Listings"].tap()
        let firstListing = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Opens listing details")).firstMatch
        // Fall back to the first cell-like button in the list if the accessibility hint isn't matched this way.
        let target = firstListing.exists ? firstListing : app.scrollViews.buttons.firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.tap()

        let messageButton = app.buttons["homeDetail.messageHostButton"]
        guard messageButton.waitForExistence(timeout: 10) else {
            throw XCTSkip("No messageable listing available in this environment")
        }
        messageButton.tap()

        if app.buttons["Request a Stay"].waitForExistence(timeout: 5) {
            app.buttons["Request a Stay"].tap()
            app.buttons["Send"].tap()
        }

        let draft = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH %@", "Message ")).firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        draft.tap()
        draft.typeText("Looking forward to it!")
        app.buttons["Send message"].tap()

        XCTAssertTrue(app.staticTexts["Looking forward to it!"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
