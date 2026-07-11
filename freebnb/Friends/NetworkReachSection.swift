//
//  NetworkReachSection.swift
//  freebnb
//
//  Draws the "Your network" section on the Friends page (feature 34): a headline
//  count of homes within reach, then the friends who host them, so the graph is
//  something you can see instead of infer. Membership and counts are decided by
//  `NetworkReach`; this file only renders the result.
//

import SwiftUI

struct NetworkReachSection: View {
    let reach: NetworkReach

    /// Keep the section a glance, not a second friends list.
    private let hostLimit = 5

    var body: some View {
        Section("Your network") {
            headline

            ForEach(reach.hosts.prefix(hostLimit)) { host in
                NetworkReachRow(host: host)
            }

            if reach.extendedCount > 0 {
                HStack(spacing: 12) {
                    Image(systemName: "person.3.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .frame(width: 40)
                    Text("\(reach.extendedCount) more through friends of friends")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var headline: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2)
                .foregroundColor(Color.accent)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(reach.totalHomes) home\(reach.totalHomes == 1 ? "" : "s") within reach")
                    .font(.headline)
                Text("through your friends and theirs")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NetworkReachRow: View {
    let host: NetworkReach.HostReach

    var body: some View {
        HStack(spacing: 12) {
            InitialsAvatar(name: host.displayName)
            Text(host.displayName)
                .font(.body)
            Spacer()
            Text("\(host.homeCount) home\(host.homeCount == 1 ? "" : "s")")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host.displayName), \(host.homeCount) home\(host.homeCount == 1 ? "" : "s") reachable")
    }
}

#Preview {
    List {
        NetworkReachSection(reach: PreviewData.reach)
    }
}
