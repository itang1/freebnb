//
//  freebnbWidgetsBundle.swift
//  freebnbWidgets
//
//  The widget extension entry point. Bundles the two home-screen widgets and the
//  current-stay Live Activity.
//

import WidgetKit
import SwiftUI

@main
struct FreeBNBWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextTripWidget()
        PendingRequestsWidget()
        StayLiveActivityWidget()
    }
}
