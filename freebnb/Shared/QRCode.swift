//
//  QRCode.swift
//  freebnb
//
//  Renders a string as a scannable QR code on-device. The invite sheet encodes the same invite link as
//  sharing, so a
//  nearby friend can scan it with the stock Camera: no network or permission. The link carries no identity
//  and takes no action.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum QRCode {
    /// A crisp QR image for `string`, or nil if CoreImage can't encode it. `scale` enlarges the
    /// one-pixel-per-module
    /// bitmap; render with `.interpolation(.none)` so SwiftUI doesn't blur it unscannable.
    static func image(for string: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium error correction recovers ~15%, enough for an angled phone camera without bloating modules.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
