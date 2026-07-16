//
//  StayLiveActivityWidget.swift
//  freebnbWidgets
//
//  The current-stay Live Activity (feature 21): Lock Screen banner plus the three
//  Dynamic Island presentations. Purely presentational — it renders whatever
//  `StayActivityAttributes` / `ContentState` the app hands it, and a tap deep
//  links into the Stays tab.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct StayLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: StayActivityAttributes.self) { context in
            // Lock Screen / banner presentation.
            StayLockScreenView(context: context)
                .widgetURL(URL(string: "freebnb://stays"))
                .activityBackgroundTint(Color.black.opacity(0.25))
        } dynamicIsland: { context in
            let phase = context.state.phase
            let isHost = context.attributes.isHost
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.city).font(.headline).lineLimit(1)
                    } icon: {
                        Image(systemName: phase.symbolName).foregroundStyle(WidgetPalette.accent)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(isHost ? "Hosting" : "Your stay")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(phase.statusText(isHost: isHost))
                            .font(.subheadline.weight(.semibold))
                        Text(dateRange(context.attributes))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: phase.symbolName).foregroundStyle(WidgetPalette.accent)
            } compactTrailing: {
                Text(context.attributes.city).lineLimit(1)
            } minimal: {
                Image(systemName: phase.symbolName).foregroundStyle(WidgetPalette.accent)
            }
            .widgetURL(URL(string: "freebnb://stays"))
        }
    }

    private func dateRange(_ attributes: StayActivityAttributes) -> String {
        let f = WidgetDateFormatters.shortDay
        return "\(f.string(from: attributes.checkIn)) – \(f.string(from: attributes.checkOut))"
    }
}

private struct StayLockScreenView: View {
    let context: ActivityViewContext<StayActivityAttributes>

    private var phase: StayPhase { context.state.phase }
    private var attributes: StayActivityAttributes { context.attributes }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: phase.symbolName)
                .font(.title2)
                .foregroundStyle(WidgetPalette.accent)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(phase.statusText(isHost: attributes.isHost))
                    .font(.subheadline.weight(.semibold))
                Text(attributes.listingLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 3) {
                Text(attributes.city)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                Text("\(WidgetDateFormatters.shortDay.string(from: attributes.checkIn)) – \(WidgetDateFormatters.shortDay.string(from: attributes.checkOut))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }
}
