//
//  CachedAsyncImage.swift
//  freebnb
//
//  Drop-in AsyncImage replacement for feed imagery: AsyncImage decodes at full resolution each appearance,
//  stuttering
//  scrolls. This downsamples to the drawn pixels and keeps the decoded result in a shared in-memory cache.
//

import ImageIO
import SwiftUI

/// Mirrors `AsyncImage`'s phases so call sites can switch the same way.
enum CachedImagePhase {
    case empty
    case success(Image)
    case failure
}

struct CachedAsyncImage<Content: View>: View {
    /// What the decoded image is cached under. A plain URL for ordinary images; for a listing photo, its stored
    /// reference, which stays put while the signed URL it resolves to changes every hour.
    private let cacheKey: String?
    private let resolveURL: @MainActor () async throws -> URL?
    /// The largest dimension in points the image is drawn at; decoded to this times the display scale, no bigger.
    let maxPointSize: CGFloat
    @ViewBuilder let content: (CachedImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: CachedImagePhase = .empty

    init(url: URL?, maxPointSize: CGFloat, @ViewBuilder content: @escaping (CachedImagePhase) -> Content) {
        self.cacheKey = url?.absoluteString
        self.resolveURL = { url }
        self.maxPointSize = maxPointSize
        self.content = content
    }

    /// A listing photo by its stored reference (`Home.photoURLs`). The object can't be read directly, so the
    /// URL comes from `ListingPhotoLinks`, which asks the server for a short-lived signed one.
    init(
        listingPhoto reference: String,
        homeID: String,
        maxPointSize: CGFloat,
        @ViewBuilder content: @escaping (CachedImagePhase) -> Content
    ) {
        self.cacheKey = "\(homeID)/\(reference)"
        self.resolveURL = { try await ListingPhotoLinks.shared.url(for: reference, homeID: homeID) }
        self.maxPointSize = maxPointSize
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: cacheKey) {
                guard let cacheKey else { return }
                let maxPixel = maxPointSize * displayScale
                if let cached = DownsampledImageLoader.cached(key: cacheKey, maxPixelSize: maxPixel) {
                    phase = .success(Image(uiImage: cached))
                    return
                }
                do {
                    guard let url = try await resolveURL() else { return }
                    let image = try await DownsampledImageLoader.load(url: url, cacheKey: cacheKey, maxPixelSize: maxPixel)
                    phase = .success(Image(uiImage: image))
                } catch is CancellationError {
                    // Scrolled away mid-download; leave the phase so the next appearance restarts the load.
                } catch {
                    phase = .failure
                }
            }
    }
}

/// Downloads and downsamples in one step so the full-resolution bitmap is never decoded; cached by key (the URL,
/// or a listing photo's stored reference) and target size.
enum DownsampledImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024  // decoded bytes, evicted under memory pressure
        return cache
    }()

    static func cached(key cacheKey: String, maxPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: key(cacheKey, maxPixelSize))
    }

    static func load(url: URL, cacheKey: String, maxPixelSize: CGFloat) async throws -> UIImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        // Decode off the caller's actor; ImageIO thumbnailing never materialises the full bitmap.
        let image = try await Task.detached(priority: .userInitiated) {
            try downsample(data: data, maxPixelSize: maxPixelSize)
        }.value
        cache.setObject(image, forKey: key(cacheKey, maxPixelSize), cost: decodedCost(of: image))
        return image
    }

    private static func key(_ cacheKey: String, _ maxPixelSize: CGFloat) -> NSString {
        "\(cacheKey)#\(Int(maxPixelSize))" as NSString
    }

    private static func decodedCost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    private static func downsample(data: Data, maxPixelSize: CGFloat) throws -> UIImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw URLError(.cannotDecodeContentData)
        }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    // No network in previews: the empty and failure phases are what render.
    VStack(spacing: 12) {
        CachedAsyncImage(url: nil, maxPointSize: 400) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                Color.red.opacity(0.2)
            case .empty:
                Color.accent.opacity(0.3).overlay(ProgressView())
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    .padding()
}
