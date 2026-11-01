//
//  PhotoUploader.swift
//  freebnb
//
//  Listing-photo storage abstraction. `FirebaseStoragePhotoUploader` is the app's implementation;
//  `NoopPhotoUploader` is the default so tests and previews never touch Storage.
//

import Foundation

protocol PhotoUploader: Sendable {
    /// Uploads an already prepared JPEG (see `ListingPhotoProcessor`) and returns the `gs://` reference the
    /// listing stores. Never a download URL: those carry a token that reads the object past storage.rules.
    /// Viewers get a short-lived signed URL from `ListingPhotoLinks` instead. Paths are scoped by host and
    /// listing so storage.rules can enforce ownership.
    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL
    /// Removes a previously uploaded photo by its stored reference.
    func delete(photoURL: URL) async throws
}

enum PhotoUploaderError: LocalizedError {
    case notConfigured
    case notAStoragePhoto

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Photo uploads aren't set up yet. Enable Firebase Storage and add a PhotoUploader implementation."
        case .notAStoragePhoto:
            return "That photo isn't one of this listing's uploads."
        }
    }
}

/// Default stand-in so tests and previews never reach Storage; uploads throw `notConfigured` so failures are
/// loud, and deletes have nothing to remove.
struct NoopPhotoUploader: PhotoUploader {
    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL {
        throw PhotoUploaderError.notConfigured
    }

    func delete(photoURL: URL) async throws {}
}

/// Where listing photos live in Storage. Mirrors `match /listings/{hostUserID}/{listingID}/{allPaths=**}` in
/// storage.rules and `homePhotosPrefix` in functions/src/paths.ts.
enum ListingPhotoPath {
    static func folder(hostUserID: String, listingID: String) -> String {
        "listings/\(hostUserID)/\(listingID)/"
    }

    /// A fresh object path. The filename is a random UUID on every upload, so a path is never reused and the
    /// bytes behind a stored reference never change (which is what lets images be cached by reference).
    /// No client can read the object directly; see `ListingPhotoLinks`.
    static func newObjectPath(hostUserID: String, listingID: String) -> String {
        folder(hostUserID: hostUserID, listingID: listingID) + UUID().uuidString.lowercased() + ".jpg"
    }

    /// The `gs://{bucket}/{path}` reference a listing stores for an uploaded photo.
    static func storedReference(bucket: String, objectPath: String) -> URL? {
        URL(string: "gs://\(bucket)/\(objectPath)")
    }

    /// The object path a stored photo reference points at: a `gs://{bucket}/{path}` reference, or a Firebase
    /// download URL that a listing saved before photos were locked down may still carry. Nil for anything
    /// else. Mirrors `objectPathFromPhotoRef` in functions/src/listingPhotos.ts.
    static func objectPath(fromStoredReference url: URL) -> String? {
        if url.scheme == "gs" {
            guard url.host?.isEmpty == false else { return nil }
            let path = String(url.path.drop(while: { $0 == "/" }))
            return path.isEmpty ? nil : path
        }
        return objectPath(fromDownloadURL: url)
    }

    /// The object path inside a Firebase Storage download URL
    /// (`https://firebasestorage.googleapis.com/v0/b/{bucket}/o/{percent-encoded path}?alt=media&token=…`,
    /// or the emulator's `http://host:9199/v0/b/…` equivalent). Nil for anything else.
    static func objectPath(fromDownloadURL url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 5, parts[0] == "v0", parts[1] == "b", parts[3] == "o" else { return nil }
        guard let path = String(parts[4]).removingPercentEncoding, !path.isEmpty else { return nil }
        return path
    }
}
