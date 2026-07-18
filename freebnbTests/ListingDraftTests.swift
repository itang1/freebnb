//
//  ListingDraftTests.swift
//  freebnbTests
//
//  Covers listing drafts and duplication (feature 13). The load-bearing
//  distinction is between the listing that *seeds* the form and the listing a
//  save *overwrites*: duplication is the one mode where those differ, and getting
//  it wrong would silently overwrite the listing the host meant to copy.
//

import Foundation
import Testing
@testable import freebnb

private func makeAmenities() -> Amenities {
    Amenities(
        hasAC: true, hasHeating: false, hasKitchen: true, hasFridgeSpace: false,
        hasMicrowave: false, hasTV: false, hasWifi: true,
        hasPrivateGuestBathroom: true, hostHasPets: false, parkingDetails: "Driveway",
        hasInUnitLaundry: false, hasCoinLaundryNearby: true,
        providesPillows: true, providesBlankets: false, providesTowels: true,
        providesToiletries: false, foodProvision: .some
    )
}

private func makeHome(id: String = "home-1") -> Home {
    var home = Home(
        hostUserID: "host",
        hostName: "Host",
        address: Address(city: "Pasadena", state: "CA", zip: "91103"),
        description: "Next to the Rose Bowl.",
        contactPreference: .contactInfo,
        hostContactInfo: "host@example.com",
        hostMotivation: .eager,
        sleeping: Sleeping(numGuestRooms: 2, arrangements: ["bed": 1, "couch": 2]),
        guestPolicy: GuestPolicy(maxGuests: 4, maxStayDays: 10, kidsAllowed: false, guestPetsAllowed: true),
        amenities: makeAmenities(),
        cancellationPolicy: .strict
    )
    home.id = id
    home.createdAt = Date(timeIntervalSince1970: 1_000_000)
    return home
}

/// A `UserDefaults` suite of its own per test, so a draft written by one test is
/// never visible to another and nothing touches the app's real defaults.
private func makeDefaults() -> UserDefaults {
    let suite = "listingDraftTests.\(UUID().uuidString)"
    // A fresh suite name cannot fail to open, but a nil here would silently fall
    // back to the standard defaults, which the tests must never write to.
    guard let defaults = UserDefaults(suiteName: suite) else {
        fatalError("could not open a private UserDefaults suite")
    }
    return defaults
}

struct ListingFormModeTests {
    @Test func createSeedsNothingAndOverwritesNothing() {
        #expect(ListingFormMode.create.source == nil)
        #expect(ListingFormMode.create.target == nil)
        #expect(ListingFormMode.create.isDraftBacked)
    }

    @Test func editBothSeedsFromAndOverwritesTheSameListing() {
        let home = makeHome()
        #expect(ListingFormMode.edit(home).source == home)
        #expect(ListingFormMode.edit(home).target == home)
    }

    /// The whole point of duplication: keep the fields, drop the identity. A
    /// `target` here would overwrite the listing being copied.
    @Test func duplicateSeedsFromTheListingButOverwritesNothing() {
        let home = makeHome()
        #expect(ListingFormMode.duplicate(home).source == home)
        #expect(ListingFormMode.duplicate(home).target == nil)
    }

    /// An edit has a saved document behind it, and a duplicate is one tap from
    /// being recreated. Restoring a stale draft over either would discard exactly
    /// the listing the host just asked for.
    @Test func onlyAFromScratchListingIsDraftBacked() {
        let home = makeHome()
        #expect(!ListingFormMode.edit(home).isDraftBacked)
        #expect(!ListingFormMode.duplicate(home).isDraftBacked)
    }
}

@MainActor
struct DuplicationTests {
    @Test func duplicateCopiesEveryFieldOffTheSourceListing() {
        let home = makeHome()
        let vm = CreateListingViewModel(mode: .duplicate(home))

        #expect(vm.city == "Pasadena")
        #expect(vm.stateField == "CA")
        #expect(vm.zip == "91103")
        #expect(vm.numGuestRooms == 2)
        #expect(vm.maxGuests == 4)
        #expect(vm.maxStayDays == 10)
        #expect(vm.sleepingCounts == [.bed: 1, .couch: 2])
        #expect(vm.kidsAllowed == false)
        #expect(vm.guestPetsAllowed == true)
        #expect(vm.hasWifi)
        #expect(vm.hasPrivateGuestBathroom)
        #expect(vm.parkingDetails == "Driveway")
        #expect(vm.foodProvision == .some)
        #expect(vm.description == "Next to the Rose Bowl.")
        #expect(vm.contactPreference == .contactInfo)
        #expect(vm.hostContactInfo == "host@example.com")
        #expect(vm.hostMotivation == .eager)
        #expect(vm.cancellationPolicy == .strict)
    }

    /// The street is not on the public listing document, so it arrives later from
    /// the private location subdoc. Until it does, the form cannot be saved.
    @Test func duplicateStartsWithNoStreetAndCannotBeSavedYet() {
        let vm = CreateListingViewModel(mode: .duplicate(makeHome()))
        #expect(vm.street.isEmpty)
        #expect(!vm.canSave(displayName: "Host"))
    }

    /// A fillable form, save-ready except for whatever the caller changes.
    private func readyToSave(mode: ListingFormMode = .create) -> CreateListingViewModel {
        let vm = CreateListingViewModel(mode: mode)
        vm.street = "1 Main St"
        vm.city = "Pasadena"
        vm.stateField = "CA"
        vm.zip = "91101"
        vm.sleepingCounts = [.bed: 1]
        vm.title = "The Attic Room"
        return vm
    }

    /// Every listing carries a name now. Without one the request sheet and the
    /// chat banner fall back to "<hostName>'s place", which says nothing once a
    /// host has a second home.
    @Test func aListingCannotBeSavedWithoutATitle() {
        let vm = readyToSave()
        #expect(vm.canSave(displayName: "Host"))

        vm.title = ""
        #expect(!vm.canSave(displayName: "Host"))

        // Whitespace is not a name.
        vm.title = "   "
        #expect(!vm.canSave(displayName: "Host"))
    }

    /// Two homes sharing a name leaves every surface that names one of them
    /// unable to say which, which is the whole point of the field.
    @Test func aListingCannotReuseAnotherListingsTitle() {
        let vm = readyToSave()
        #expect(!vm.canSave(displayName: "Host", takenTitles: ["The Attic Room"]))
        // Case and surrounding space don't make it a different name.
        #expect(!vm.canSave(displayName: "Host", takenTitles: ["the attic room"]))
        vm.title = "  The Attic Room  "
        #expect(!vm.canSave(displayName: "Host", takenTitles: ["The Attic Room"]))

        vm.title = "The Garden Studio"
        #expect(vm.canSave(displayName: "Host", takenTitles: ["The Attic Room"]))
    }

    /// The host shouldn't have to name their first listing at all.
    @Test func aFirstListingIsNamedAfterTheHostAndCity() {
        let vm = CreateListingViewModel(mode: .create)
        vm.city = "Pasadena"
        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        #expect(vm.title == "Devna's Place in Pasadena")
    }

    /// A second home in the same city can't take the same suggestion as the
    /// first, so the suggestion counts instead.
    @Test func laterListingsInOneCityGetOrdinalSuggestions() {
        let vm = CreateListingViewModel(mode: .create)
        vm.city = "Pasadena"

        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: ["Devna's Place in Pasadena"])
        #expect(vm.title == "Devna's Second Place in Pasadena")

        vm.applySuggestedTitleIfUntouched(
            hostName: "Devna",
            taken: ["Devna's Place in Pasadena", "Devna's Second Place in Pasadena"]
        )
        #expect(vm.title == "Devna's Third Place in Pasadena")
    }

    /// A second home in a different city is already distinct, so it keeps the
    /// plain form rather than being counted.
    @Test func aListingInANewCityKeepsThePlainSuggestion() {
        let vm = CreateListingViewModel(mode: .create)
        vm.city = "Ojai"
        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: ["Devna's Place in Pasadena"])
        #expect(vm.title == "Devna's Place in Ojai")
    }

    /// The suggestion follows the city while the field is untouched, and stops
    /// the moment the host makes the name their own.
    @Test func aTypedTitleIsNeverOverwrittenByASuggestion() {
        let vm = CreateListingViewModel(mode: .create)
        vm.city = "Pasadena"
        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        vm.noteTitleChanged()
        #expect(!vm.titleWasEdited, "applying a suggestion is not the host editing it")

        // The address changes; the untouched suggestion follows it.
        vm.city = "Ojai"
        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        #expect(vm.title == "Devna's Place in Ojai")

        // Now the host types, and nothing overwrites them again.
        vm.title = "The Attic Room"
        vm.noteTitleChanged()
        #expect(vm.titleWasEdited)
        vm.city = "Ventura"
        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        #expect(vm.title == "The Attic Room")
    }

    /// The form names the listing the moment it opens. That must not count as
    /// work in progress, or opening the sheet and closing it would leave a draft
    /// claiming the host had started one.
    @Test func aSuggestedNameAloneLeavesTheDraftPristine() {
        let vm = CreateListingViewModel(mode: .create)
        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        #expect(!vm.title.isEmpty)
        #expect(vm.draft.isPristine)

        vm.title = "The Attic Room"
        vm.noteTitleChanged()
        #expect(!vm.draft.isPristine)
    }

    /// Restoring a draft has to remember whether the host wrote the name or the
    /// form suggested it. Inferring it from "the title isn't empty" made every
    /// restored draft look host-written, which froze the suggestion so it stopped
    /// following the city.
    @Test func aRestoredDraftRemembersWhoWroteTheTitle() {
        let userID = "host"
        let store = ListingDraftStore(defaults: makeDefaults())

        var suggested = ListingDraft()
        suggested.city = "Pasadena"
        suggested.title = "Devna's Place in Pasadena"
        suggested.titleWasEdited = false
        store.save(suggested, userID: userID)

        let vm = CreateListingViewModel(mode: .create)
        vm.restoreDraft(from: store, userID: userID)
        #expect(!vm.titleWasEdited)
        vm.city = "Ojai"
        vm.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        #expect(vm.title == "Devna's Place in Ojai")

        var typed = suggested
        typed.title = "The Attic Room"
        typed.titleWasEdited = true
        store.save(typed, userID: userID)

        let second = CreateListingViewModel(mode: .create)
        second.restoreDraft(from: store, userID: userID)
        #expect(second.titleWasEdited)
        second.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        #expect(second.title == "The Attic Room")
    }

    /// A duplicate copies the source listing's name, which is exactly the one
    /// name it may not keep. It starts untouched so a fresh suggestion replaces
    /// it; an edit keeps the name the host already chose.
    @Test func aDuplicateTakesAFreshNameButAnEditKeepsItsOwn() {
        var home = makeHome()
        home.title = "The Attic Room"

        let duplicate = CreateListingViewModel(mode: .duplicate(home))
        #expect(!duplicate.titleWasEdited)
        duplicate.city = "Pasadena"
        duplicate.applySuggestedTitleIfUntouched(hostName: "Devna", taken: ["The Attic Room"])
        #expect(duplicate.title == "Devna's Place in Pasadena")

        let edit = CreateListingViewModel(mode: .edit(home))
        #expect(edit.titleWasEdited)
        edit.applySuggestedTitleIfUntouched(hostName: "Devna", taken: [])
        #expect(edit.title == "The Attic Room")
    }

    @Test func aFreshCreateFormMatchesAPristineDraft() {
        let vm = CreateListingViewModel(mode: .create)
        #expect(vm.draft.isPristine)
    }

    /// The repository save is a full-document overwrite, so anything the form
    /// doesn't manage must ride along from the stored listing. Losing these
    /// once meant an edit silently reopened every blocked date and stripped the
    /// listing's photos.
    @Test func editingKeepsTheFieldsTheFormDoesNotManage() {
        var home = makeHome()
        home.blockedDateRanges = [DateRange(start: Date(timeIntervalSince1970: 2_000_000),
                                            end: Date(timeIntervalSince1970: 2_500_000))]
        home.photoURLs = ["https://example.com/cover.jpg"]
        home.coHostUserIDs = ["cohost-1"]
        let vm = CreateListingViewModel(mode: .edit(home))

        let rebuilt = vm.makeHome(hostUserID: home.hostUserID, hostName: home.hostName, friendIDs: ["friend-1"])

        #expect(rebuilt.id == home.id)
        #expect(rebuilt.createdAt == home.createdAt)
        #expect(rebuilt.blockedDateRanges == home.blockedDateRanges)
        #expect(rebuilt.photoURLs == home.photoURLs)
        #expect(rebuilt.coHostUserIDs == home.coHostUserIDs)
        // The ACL is rebuilt from the saving host's current friends, not kept.
        #expect(rebuilt.allowedViewerIDs == ["host", "friend-1"])
    }

    /// A duplicate is a new listing that starts out looking like an old one; it
    /// must not inherit the source's identity, photos, or blocked dates.
    @Test func duplicatingKeepsNoIdentityOrUnmanagedFields() {
        var home = makeHome()
        home.blockedDateRanges = [DateRange(start: Date(timeIntervalSince1970: 2_000_000),
                                            end: Date(timeIntervalSince1970: 2_500_000))]
        home.photoURLs = ["https://example.com/cover.jpg"]
        let vm = CreateListingViewModel(mode: .duplicate(home))

        let rebuilt = vm.makeHome(hostUserID: home.hostUserID, hostName: home.hostName, friendIDs: [])

        #expect(rebuilt.id != home.id)
        #expect(rebuilt.blockedDateRanges == nil)
        #expect(rebuilt.photoURLs == nil)
    }
}

@MainActor
struct ListingDraftPersistenceTests {
    private let userID = "host"

    @Test func draftSurvivesARoundTripThroughTheForm() {
        let vm = CreateListingViewModel(mode: .create)
        vm.street = "123 Oak St"
        vm.city = "Portland"
        vm.stateField = "OR"
        vm.zip = "97201"
        vm.sleepingCounts = [.couch: 1, .futon: 2]
        vm.hasWifi = true
        vm.foodProvision = .bareMinimum
        vm.description = "Spare couch."

        let store = ListingDraftStore(defaults: makeDefaults())
        vm.persistDraft(to: store, userID: userID)

        let restored = CreateListingViewModel(mode: .create)
        restored.restoreDraft(from: store, userID: userID)

        #expect(restored.restoredDraft)
        #expect(restored.street == "123 Oak St")
        #expect(restored.city == "Portland")
        #expect(restored.zip == "97201")
        // The enum-keyed map round-trips through its raw-value form.
        #expect(restored.sleepingCounts == [.couch: 1, .futon: 2])
        #expect(restored.hasWifi)
        #expect(restored.foodProvision == .bareMinimum)
        #expect(restored.description == "Spare couch.")
    }

    /// An untouched form is not a draft. Storing one would make the next open
    /// announce a "restored draft" that contains nothing.
    @Test func pristineFormIsNeverStored() {
        let store = ListingDraftStore(defaults: makeDefaults())
        let vm = CreateListingViewModel(mode: .create)
        vm.persistDraft(to: store, userID: userID)
        #expect(store.load(userID: userID) == nil)
    }

    /// Emptying the form clears the draft behind it, rather than leaving the old
    /// one to reappear on the next open.
    @Test func savingAPristineDraftClearsAStoredOne() {
        let store = ListingDraftStore(defaults: makeDefaults())
        var draft = ListingDraft()
        draft.city = "Portland"
        store.save(draft, userID: userID)
        #expect(store.load(userID: userID) != nil)

        store.save(ListingDraft(), userID: userID)
        #expect(store.load(userID: userID) == nil)
    }

    @Test func discardEmptiesTheFormAndForgetsTheDraft() {
        let store = ListingDraftStore(defaults: makeDefaults())
        let vm = CreateListingViewModel(mode: .create)
        vm.city = "Portland"
        vm.persistDraft(to: store, userID: userID)

        vm.discardDraft(from: store, userID: userID)

        #expect(vm.city.isEmpty)
        #expect(vm.draft.isPristine)
        #expect(!vm.restoredDraft)
        #expect(store.load(userID: userID) == nil)
    }

    /// Two accounts on one device must not see each other's half-typed address.
    @Test func draftsAreScopedToTheUserWhoStartedThem() {
        let store = ListingDraftStore(defaults: makeDefaults())
        var draft = ListingDraft()
        draft.street = "123 Oak St"
        store.save(draft, userID: "host-a")

        #expect(store.load(userID: "host-b") == nil)
        #expect(store.load(userID: "host-a")?.street == "123 Oak St")
    }

    /// A signed-out or anonymous session has no user id to key a draft by, and a
    /// street address is not something to store under a shared one.
    @Test func anonymousSessionStoresNothing() {
        let store = ListingDraftStore(defaults: makeDefaults())
        var draft = ListingDraft()
        draft.street = "123 Oak St"
        store.save(draft, userID: "")
        #expect(store.load(userID: "") == nil)
    }

    @Test func editingFormNeitherRestoresNorPersistsADraft() {
        let store = ListingDraftStore(defaults: makeDefaults())
        var stored = ListingDraft()
        stored.city = "Portland"
        store.save(stored, userID: userID)

        let vm = CreateListingViewModel(mode: .edit(makeHome()))
        vm.restoreDraft(from: store, userID: userID)
        #expect(!vm.restoredDraft)
        #expect(vm.city == "Pasadena")

        // And an edit must not overwrite the from-scratch draft waiting behind it.
        vm.persistDraft(to: store, userID: userID)
        #expect(store.load(userID: userID)?.city == "Portland")
    }

    @Test func duplicateFormLeavesAStoredDraftAlone() {
        let store = ListingDraftStore(defaults: makeDefaults())
        var stored = ListingDraft()
        stored.city = "Portland"
        store.save(stored, userID: userID)

        let vm = CreateListingViewModel(mode: .duplicate(makeHome()))
        vm.restoreDraft(from: store, userID: userID)
        #expect(!vm.restoredDraft)
        #expect(vm.city == "Pasadena")

        vm.persistDraft(to: store, userID: userID)
        #expect(store.load(userID: userID)?.city == "Portland")
    }

    /// `Home` declares an explicit CodingKeys, which drives the encoder as well as
    /// the decoder, and `title` was missing from it. So a host could name their
    /// listing and have the name dropped on save, and every stored title decoded
    /// as nil — which took the name out of the request sheet, the chat banner, and
    /// the listing card all at once.
    @Test func aListingTitleSurvivesARoundTrip() throws {
        var home = HomeFixture.make()
        home.title = "The Clarinet Suite"

        let restored = try JSONDecoder().decode(Home.self, from: JSONEncoder().encode(home))

        #expect(restored.title == "The Clarinet Suite")
        #expect(restored.displayTitle == "The Clarinet Suite")
    }

    /// An untitled listing still has to name itself somehow.
    @Test func anUntitledListingFallsBackToTheHostName() throws {
        var home = HomeFixture.make()
        home.title = nil

        let restored = try JSONDecoder().decode(Home.self, from: JSONEncoder().encode(home))

        #expect(restored.customTitle == nil)
        #expect(restored.displayTitle == "\(home.hostName)'s place")
    }

    /// A draft is a convenience. If its stored form no longer decodes, the right
    /// answer is an empty form, not an error the host has to dismiss.
    @Test func undecodableDraftIsDiscardedRatherThanThrown() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "listingDraft.\(userID)")
        let store = ListingDraftStore(defaults: defaults)
        #expect(store.load(userID: userID) == nil)
    }
}
