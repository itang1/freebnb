//
//  BookingPolicyEditor.swift
//  freebnb
//
//  The three fields of a booking policy, as form sections. Shared by the circle
//  editor and the per-friend override sheet, because a policy set on one person
//  and a policy set on a circle are the same thing pointed at a different number
//  of people — and an editor that differed between them would sooner or later
//  differ in what it permitted.
//
//  Host-facing only. Nothing in this file is reachable from a screen a guest can
//  see.
//

import SwiftUI

struct BookingPolicyEditor: View {
    @Binding var policy: BookingPolicy

    /// Notice values worth offering. A stepper over 8760 hours would be a joke,
    /// and a free-text field invites "48h" and "two days".
    private static let noticeChoices = [0, 12, 24, 48, 72, 168, 336, 720]

    private static let periodChoices = [7, 14, 30, 90, 180, 365]

    private var capBinding: Binding<Bool> {
        Binding(
            get: { policy.maxStaysPerPeriod != nil },
            set: { on in
                policy.maxStaysPerPeriod = on ? StayFrequencyCap(count: 2, periodDays: 30) : nil
            }
        )
    }

    var body: some View {
        Section {
            ForEach(ArrivalWindow.allCases, id: \.self) { window in
                Toggle(window.displayName, isOn: arrivalBinding(window))
            }
        } header: {
            Text("Arrival times they can pick")
        } footer: {
            // Says what the guest sees, because that is the part a host cannot
            // check for themselves and the part they are most likely to get
            // wrong about this feature.
            Text(arrivalFooter)
        }

        Section {
            Picker("Minimum notice", selection: $policy.minNoticeHours) {
                ForEach(Self.noticeChoices, id: \.self) { hours in
                    Text(Self.noticeLabel(hours)).tag(hours)
                }
            }
        } footer: {
            Text(policy.minNoticeHours == 0
                 ? "They can ask for any open date, including tonight."
                 : "Dates sooner than \(Self.noticeLabel(policy.minNoticeHours).lowercased()) away show as unavailable to them.")
        }

        Section {
            Toggle("Limit how often they can book", isOn: capBinding)
            if let cap = policy.maxStaysPerPeriod {
                Stepper(value: countBinding, in: StayFrequencyCap.countRange) {
                    HStack {
                        Text("Stays")
                        Spacer()
                        Text("\(cap.count)").foregroundColor(.secondaryText)
                    }
                }
                Picker("Per", selection: periodBinding) {
                    ForEach(Self.periodChoices, id: \.self) { days in
                        Text(Self.periodLabel(days)).tag(days)
                    }
                }
            }
        } footer: {
            Text(policy.maxStaysPerPeriod == nil
                 ? "They can book as often as your calendar allows."
                 : "Once they've used these up, your calendar shows as full to them until the window resets. Stays you've already accepted are never affected.")
        }
    }

    private var arrivalFooter: String {
        let count = policy.allowedArrivalWindows.count
        if count == ArrivalWindow.allCases.count {
            return "They can pick any arrival time."
        }
        if count == 0 {
            return "Pick at least one — an arrival time has to be available to choose."
        }
        return "The others simply won't appear in their picker."
    }

    private func arrivalBinding(_ window: ArrivalWindow) -> Binding<Bool> {
        Binding(
            get: { policy.allowedArrivalOptions.contains(window.rawValue) },
            set: { on in
                var options = Set(policy.allowedArrivalOptions)
                if on { options.insert(window.rawValue) } else { options.remove(window.rawValue) }
                // Stored in the enum's order rather than tap order, so two hosts
                // who picked the same set store the same array.
                policy.allowedArrivalOptions = ArrivalWindow.allCases
                    .map(\.rawValue)
                    .filter(options.contains)
            }
        )
    }

    private var countBinding: Binding<Int> {
        Binding(
            get: { policy.maxStaysPerPeriod?.count ?? 2 },
            set: { policy.maxStaysPerPeriod?.count = $0 }
        )
    }

    private var periodBinding: Binding<Int> {
        Binding(
            get: { policy.maxStaysPerPeriod?.periodDays ?? 30 },
            set: { policy.maxStaysPerPeriod?.periodDays = $0 }
        )
    }

    static func noticeLabel(_ hours: Int) -> String {
        switch hours {
        case 0:            return "None"
        case ..<24:        return "\(hours) hours"
        case 24:           return "1 day"
        case let h where h % 168 == 0:
            let weeks = h / 168
            return "\(weeks) week\(weeks == 1 ? "" : "s")"
        default:           return "\(hours / 24) days"
        }
    }

    static func periodLabel(_ days: Int) -> String {
        switch days {
        case 7:   return "week"
        case 14:  return "2 weeks"
        case 30:  return "month"
        case 90:  return "3 months"
        case 180: return "6 months"
        case 365: return "year"
        default:  return "\(days) days"
        }
    }
}

/// One line describing what a policy does, for a circle row or a friend row.
/// "No restrictions" when it does nothing, which is what a host's Default circle
/// says until they change it.
func bookingPolicySummary(_ policy: BookingPolicy) -> String {
    if policy.isPermissive { return "No restrictions" }
    var parts: [String] = []
    let arrivals = policy.allowedArrivalWindows.count
    if arrivals < ArrivalWindow.allCases.count {
        parts.append("\(arrivals) arrival time\(arrivals == 1 ? "" : "s")")
    }
    if policy.minNoticeHours > 0 {
        parts.append("\(BookingPolicyEditor.noticeLabel(policy.minNoticeHours).lowercased()) notice")
    }
    if let cap = policy.maxStaysPerPeriod {
        parts.append(cap.summary)
    }
    return parts.joined(separator: " · ")
}
