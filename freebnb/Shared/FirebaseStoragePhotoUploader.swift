//
//  FirebaseStoragePhotoUploader.swift
//  freebnb
//
//  Uploads listing photos to Firebase Storage under listings/{hostUserID}/{listingID}/{uuid}.jpg and returns
//  the gs:// reference the listing stores.
//

import FirebaseStorage
import Foundation

struct FirebaseStoragePhotoUploader: PhotoUploader {
    func upload(imageData: Data, listingID: String, hostUserID: String) async throws -> URL {
        let path = ListingPhotoPath.newObjectPath(hostUserID: hostUserID, listingID: listingID)
        let ref = Storage.storage().reference(withPath: path)
        let metadata = StorageMetadata()
        // storage.rules only admits `image/*`; ListingPhotoProcessor always produces JPEG.
        metadata.contentType = "image/jpeg"
        // A path is never reused (random name per upload), so the bytes behind a URL never change.
        metadata.cacheControl = "private, max-age=31536000, immutable"
        _ = try await ref.putDataAsync(imageData, metadata: metadata)
        // Not `downloadURL()`: storage.rules denies client reads, and a token URL would bypass them anyway.
        guard let stored = ListingPhotoPath.storedReference(bucket: ref.bucket, objectPath: ref.fullPath) else {
            throw PhotoUploaderError.notAStoragePhoto
        }
        return stored
    }

    func delete(photoURL: URL) async throws {
        guard let path = ListingPhotoPath.objectPath(fromStoredReference: photoURL) else {
            throw PhotoUploaderError.notAStoragePhoto
        }
        try await Storage.storage().reference(withPath: path).delete()
    }
}
