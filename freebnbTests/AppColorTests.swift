//
//  AppColorTests.swift
//  freebnbTests
//
//  Guards the seam between AppColor's raw values and the asset catalog:
//  UIColor.app(_:) falls back with an assertionFailure instead of a force
//  unwrap, so a renamed or deleted colorset would otherwise only surface at
//  runtime. Hosted by the freebnb app (TEST_HOST), so UIColor(named:) reads
//  the real compiled catalog.
//

import Testing
import UIKit
@testable import freebnb

struct AppColorTests {
    @Test func everyRoleResolvesFromTheAssetCatalog() {
        for role in AppColor.allCases {
            #expect(UIColor(named: role.rawValue) != nil, "Missing colorset for \(role.rawValue)")
        }
    }

    @Test func everyRoleDefinesADistinctDarkVariant() {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for role in AppColor.allCases {
            let color = UIColor.app(role)
            #expect(
                color.resolvedColor(with: light) != color.resolvedColor(with: dark),
                "\(role.rawValue) should adapt to dark mode"
            )
        }
    }
}
