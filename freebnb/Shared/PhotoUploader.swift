//
//  PhotoUploader.swift
//  freebnb
//
//  Listing-photo upload abstraction and the no-op default used until Firebase
//  Storage is wired up. Split out of the former Repositories.swift (A2).
//

import Foundation

protocol PhotoUploader: Sendable {
    /// Uploads an image and returns the public download URL. Implementations
    /// should scope storage paths by listing so rules can enforce ownership.
    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL
}

enum PhotoUploaderError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Photo uploads aren't set up yet. Enable Firebase Storage and add a PhotoUploader implementation."
        }
    }
}

/// Default stand-in so the rest of the app can be built and run without
/// Firebase Storage linked. Any attempt to upload throws `notConfigured`
/// so failures are loud, not silent.
struct NoopPhotoUploader: PhotoUploader {
    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL {
        throw PhotoUploaderError.notConfigured
    }
}
