//
//  QRCodeTests.swift
//  freebnbTests
//
//  The QR path (feature 32) has no round trip to assert against a real camera, so
//  these pin the two things that would silently break it: that a real invite URL
//  encodes at all, and that the output is scaled up rather than the raw one-module-
//  per-pixel bitmap that renders too small to scan.
//

import Foundation
import Testing
import UIKit
@testable import freebnb

struct QRCodeTests {
    @Test func encodesAnInviteURL() {
        let image = QRCode.image(for: "freebnb://invite?from=abc123")
        #expect(image != nil)
    }

    @Test func scalesUpFromTheRawModuleBitmap() {
        // A bare QR for this payload is on the order of tens of modules across; the
        // default scale must lift it well past that so it is scannable on screen.
        let image = QRCode.image(for: "freebnb://invite?from=abc123")
        #expect((image?.size.width ?? 0) > 100)
        #expect(image?.size.width == image?.size.height)
    }

    @Test func emptyStringStillEncodes() {
        // CoreImage encodes an empty message rather than failing; guard against a
        // regression that would return nil and blank the invite sheet.
        #expect(QRCode.image(for: "") != nil)
    }
}
