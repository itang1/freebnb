//
//  QRCode.swift
//  freebnb
//
//  Renders a string as a scannable QR code on-device (feature 32). The invite
//  sheet encodes the same plain `freebnb://invite` link the share flow uses, so a
//  friend standing next to you can point the stock Camera app at it and open the
//  app. No network, no new permission: the OS camera does the scanning. The link
//  carries no identity and takes no action — friends are added in-app, never by a
//  scan.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

enum QRCode {
    /// A crisp QR image for `string`, or nil if CoreImage could not encode it.
    ///
    /// The generator emits a tiny bitmap (one pixel per module); `scale` blows it
    /// up so it stays sharp at display size. Render it with `.interpolation(.none)`
    /// so SwiftUI does not blur the edges back into unscannability.
    static func image(for string: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium error correction: recovers ~15% of the code, enough to survive a
        // phone camera at an angle without bloating the module count.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
