//
//  CachedAsyncImage.swift
//  freebnb
//
//  Drop-in replacement for AsyncImage for feed imagery. AsyncImage decodes a
//  photo at its full native resolution every time it appears, which is what
//  makes an image-heavy scroll stutter. This view downsamples to the pixels
//  actually drawn and keeps the decoded result in a shared in-memory cache,
//  so a card scrolling back on screen renders immediately.
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
    let url: URL?
    /// The largest dimension, in points, the image will be drawn at. The
    /// loader decodes to this times the display scale and no bigger.
    let maxPointSize: CGFloat
    @ViewBuilder let content: (CachedImagePhase) -> Content

    @Environment(\.displayScale) private var displayScale
    @State private var phase: CachedImagePhase = .empty

    var body: some View {
        content(phase)
            .task(id: url) {
                guard let url else { return }
                let maxPixel = maxPointSize * displayScale
                if let cached = DownsampledImageLoader.cached(url: url, maxPixelSize: maxPixel) {
                    phase = .success(Image(uiImage: cached))
                    return
                }
                do {
                    let image = try await DownsampledImageLoader.load(url: url, maxPixelSize: maxPixel)
                    phase = .success(Image(uiImage: image))
                } catch is CancellationError {
                    // Scrolled away mid-download; leave the phase alone so the
                    // next appearance restarts the load.
                } catch {
                    phase = .failure
                }
            }
    }
}

/// Downloads and downsamples in one step, so the full-resolution bitmap is
/// never decoded. Decoded images are cached by URL and target size.
enum DownsampledImageLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024  // decoded bytes, evicted under memory pressure
        return cache
    }()

    static func cached(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        cache.object(forKey: key(url, maxPixelSize))
    }

    static func load(url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        let (data, _) = try await URLSession.shared.data(from: url)
        // Decode off the caller's actor; ImageIO thumbnailing never
        // materialises the full-size bitmap.
        let image = try await Task.detached(priority: .userInitiated) {
            try downsample(data: data, maxPixelSize: maxPixelSize)
        }.value
        cache.setObject(image, forKey: key(url, maxPixelSize), cost: decodedCost(of: image))
        return image
    }

    private static func key(_ url: URL, _ maxPixelSize: CGFloat) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixelSize))" as NSString
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
