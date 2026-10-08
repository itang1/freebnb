//
//  SpotlightIndexer.swift
//  freebnb
//
//  Indexes the user's saved listings into Spotlight so a saved place is searchable and deep-links back.
//  Only saved listings (a private set) and public card fields are indexed, never the street address;
//  entirely on-device.
//

import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

enum SpotlightIndexer {
    /// Groups every FreeBNB entry under one domain so the set can be reconciled or cleared in one call.
    static let domainIdentifier = "saved-listings"

    // MARK: - Pure attribute builders (unit-tested)

    /// The result title, mirroring the listing card: host, then neighbourhood.
    static func title(for home: Home) -> String {
        "\(home.hostName) · \(home.address.city), \(home.address.state)"
    }

    /// The supporting line: the host's own words or a neutral fallback, never the street address.
    static func contentDescription(for home: Home) -> String {
        if let text = home.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        return "A place to stay in \(home.address.city), \(home.address.state)."
    }

    /// Extra query terms so a city or host search surfaces the listing even if absent from the title.
    static func keywords(for home: Home) -> [String] {
        [home.address.city, home.address.state, home.hostName, "FreeBNB"]
    }

    // MARK: - Index item construction

    static func attributeSet(for home: Home) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = title(for: home)
        attributes.contentDescription = contentDescription(for: home)
        attributes.keywords = keywords(for: home)
        attributes.city = home.address.city
        attributes.stateOrProvince = home.address.state
        return attributes
    }

    /// The searchable item; its `uniqueIdentifier` is the listing id, which a tap hands back for deep-linking.
    static func item(for home: Home) -> CSSearchableItem {
        CSSearchableItem(
            uniqueIdentifier: home.id,
            domainIdentifier: domainIdentifier,
            attributeSet: attributeSet(for: home)
        )
    }

    // MARK: - Reconciliation

    /// Makes the index reflect exactly `homes`: clears the domain, then re-adds the set (the
    /// delete's completion runs the indexing so they can't race). Idempotent; `index` is injectable for tests.
    static func sync(savedHomes homes: [Home], index: CSSearchableIndex = .default()) {
        index.deleteSearchableItems(withDomainIdentifiers: [domainIdentifier]) { _ in
            guard !homes.isEmpty else { return }
            index.indexSearchableItems(homes.map(item(for:))) { _ in }
        }
    }
}
