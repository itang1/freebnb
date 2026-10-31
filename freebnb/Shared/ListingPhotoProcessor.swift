//
//  ListingPhotoProcessor.swift
//  freebnb
//
//  Prepares a picked photo for upload: downscale, re-encode as JPEG, drop every byte of metadata.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ListingPhotoProcessor {
    /// Long edge in pixels. Large enough for a full-screen detail carousel on any current iPhone.
    static let maxPixelSize = 2048
    static let compressionQuality = 0.8

    enum ProcessingError: LocalizedError {
        case unreadableImage
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "That file couldn't be read as a photo."
            case .encodingFailed: return "That photo couldn't be prepared for upload."
            }
        }
    }

    /// Decodes any format ImageIO reads (HEIC, JPEG, PNG, …), bakes the EXIF orientation into the pixels,
    /// shrinks it so the long edge is at most `maxPixelSize` (never upscales), and writes a fresh JPEG.
    ///
    /// Only the pixels are carried over. The source's properties are never handed to the destination, so EXIF,
    /// GPS, TIFF (camera make and model), IPTC and XMP are all dropped: a host's exact location must not leak
    /// through a photo of their front door. Pure and synchronous, so call it off the main actor.
    static func prepareForUpload(_ data: Data, maxPixelSize: Int = maxPixelSize) throws -> Data {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw ProcessingError.unreadableImage
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ProcessingError.unreadableImage
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ProcessingError.encodingFailed
        }
        let destinationOptions = [kCGImageDestinationLossyCompressionQuality: compressionQuality] as CFDictionary
        CGImageDestinationAddImage(destination, image, destinationOptions)
        guard CGImageDestinationFinalize(destination) else { throw ProcessingError.encodingFailed }
        return output as Data
    }
}
