//
//  LegalLinks.swift
//  freebnb
//

import Foundation

/// Single source of truth for the app's legal documents. The documents
/// themselves live at docs/public/ in the repo, not in the app bundle, so
/// there's only one copy to keep in sync.
enum LegalLinks {
    // swiftlint:disable force_unwrapping
    static let privacyPolicy = URL(string: "https://github.com/itang1/freebnb/blob/main/docs/public/privacy-policy.md")!
    static let termsOfService = URL(string: "https://github.com/itang1/freebnb/blob/main/docs/public/terms-of-service.md")!
    // swiftlint:enable force_unwrapping
}
