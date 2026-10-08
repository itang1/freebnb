//
//  QRCodeTests.swift
//  freebnbTests
//
//  There's no camera round trip to assert, so these pin what would silently break the QR: the invite URL encodes at all, and the output is scaled up from the unscannable one-pixel-per-module bitmap.
//

import Foundation
import Testing
import UIKit
@testable import freebnb

struct QRCodeTests {
    @Test func encodesAnInviteURL() {
        let image = QRCode.image(for: "freebnb://invite")
        #expect(image != nil)
    }

    @Test func scalesUpFromTheRawModuleBitmap() {
        // A bare QR is tens of modules across; the default scale must lift it past that to be scannable.
        let image = QRCode.image(for: "freebnb://invite")
        #expect((image?.size.width ?? 0) > 100)
        #expect(image?.size.width == image?.size.height)
    }

    @Test func emptyStringStillEncodes() {
        // CoreImage encodes an empty message rather than failing; guard a regression returning nil and blanking the invite sheet.
        #expect(QRCode.image(for: "") != nil)
    }
}
