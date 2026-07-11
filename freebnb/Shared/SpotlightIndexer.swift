//
//  SpotlightIndexer.swift
//  freebnb
//
//  Indexes the user's saved listings into iOS Spotlight (feature 40) so a saved
//  place is searchable from the home screen and, tapped, deep-links back into the
//  listing. Only *saved* listings are indexed — a private, per-user set — and only
//  the public card fields (host name, city/state, description) go into the index;
//  the street address never does. This is entirely on-device and needs no billing.
//

#if canImport(CoreSpotlight)
import CoreSpotlight
import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

enum SpotlightIndexer {
    /// Groups every FreeBNB entry under one domain so the whole set can be
    /// reconciled or cleared in a single call.
    static let domainIdentifier = "saved-listings"

    // MARK: - Pure attribute builders (unit-tested)

    /// Human title shown in a Spotlight result. Mirrors the listing card: the
    /// host, then the neighbourhood.
    static func title(for home: Home) -> String {
        "\(home.hostName) · \(home.address.city), \(home.address.state)"
    }

    /// The result's supporting line: the host's own words if any, otherwise a
    /// neutral fallback. Never includes the street address.
    static func contentDescription(for home: Home) -> String {
        if let text = home.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "A place to stay in \(home.address.city), \(home.address.state)."
    }

    /// Extra query terms so a search for the city or the host still surfaces the
    /// listing even when they aren't in the title verbatim.
    static func keywords(for home: Home) -> [String] {
        [home.address.city, home.address.state, home.hostName, "FreeBNB"]
    }

    // MARK: - Index item construction

    static func attributeSet(for home: Home) -> CSSearchableItemAttributeSet {
        let attributes: CSSearchableItemAttributeSet
        if #available(iOS 14.0, macOS 11.0, *) {
            attributes = CSSearchableItemAttributeSet(contentType: .content)
        } else {
            attributes = CSSearchableItemAttributeSet(itemContentType: "public.content")
        }
        attributes.title = title(for: home)
        attributes.contentDescription = contentDescription(for: home)
        attributes.keywords = keywords(for: home)
        attributes.city = home.address.city
        attributes.stateOrProvince = home.address.state
        return attributes
    }

    /// The searchable item for a listing. Its `uniqueIdentifier` is the listing id
    /// itself, which is what a tap hands back to the app for deep-linking.
    static func item(for home: Home) -> CSSearchableItem {
        CSSearchableItem(
            uniqueIdentifier: home.id,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet(for: home)
        )
    }

    // MARK: - Reconciliation

    /// Makes the Spotlight index reflect exactly `homes`: clears the domain, then
    /// re-adds the current set. Delete-then-index runs inside the delete's
    /// completion so the two operations can't race. Idempotent, so it is safe to
    /// call on every change to the saved set. `index` is injectable for tests.
    static func sync(savedHomes homes: [Home], index: CSSearchableIndex = .default()) {
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
            guard !homes.isEmpty else { return }
            index.indexSearchableItems(homes.map(item(for:))) { _ in }
        }
    }
}
#endif
