//
//  CirclesPage.swift
//  freebnb
//
//  Where a host manages their circles: create, rename, delete, and set each
//  one's booking rules. Reached from the Friends list, which is the only place
//  the host already thinks about these people.
//
//  Every screen in this file is the host's own. None of it is reachable from a
//  listing, a request, or any other surface a guest can open — a guest learning
//  that circles exist is the failure this feature is built to avoid.
//

import SwiftUI

struct CirclesPage: View {
    @Environment(CircleStore.self) private var circleStore
    @Environment(FriendStore.self) private var friendStore

    @State private var showingNewCircle = false
    @State private var newCircleName = ""
    @State private var actionError: String?

    private var friendIDs: [String] { friendStore.friendIDs }

    var body: some View {
        List {
            if let actionError {
                Section { InlineErrorLabel(message: actionError) }
            }

            Section {
                let counts = circleStore.memberCounts(among: friendIDs)
                ForEach(circleStore.circles) { circle in
                    NavigationLink {
                        CircleDetailPage(circle: circle)
                    } label: {
                        CircleRow(circle: circle, memberCount: counts[circle.id ?? ""] ?? 0)
                    }
                }
            } header: {
                Text("Your circles")
            } footer: {
                Text("Friends are never told which circle they're in, and nobody is told a circle exists. Changes only affect new requests — stays you've already accepted stay exactly as they are.")
            }

            Section {
                Button {
                    newCircleName = ""
                    showingNewCircle = true
                } label: {
                    Label("New circle", systemImage: "plus.circle")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle("Circles")
        .navigationBarTitleDisplayMode(.inline)
        .task { await circleStore.reconcile(friendIDs: friendIDs) }
        .alert("New circle", isPresented: $showingNewCircle) {
            TextField("Name", text: $newCircleName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await create() } }
        } message: {
            Text("Name it for yourself — nobody else ever sees it.")
        }
    }

    private func create() async {
        actionError = nil
        do { try await circleStore.createCircle(named: newCircleName) }
        catch { actionError = error.localizedDescription }
    }
}

private struct CircleRow: View {
    let circle: FriendCircle
    let memberCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(circle.name)
                    .font(.body)
                if circle.isDefault {
                    Text("Default")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondaryText.opacity(0.12), in: Capsule())
                        .foregroundColor(.secondaryText)
                }
            }
            Text("\(memberCount) friend\(memberCount == 1 ? "" : "s") · \(bookingPolicySummary(circle.policy))")
                .font(.caption)
                .foregroundColor(.secondaryText)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - One circle

struct CircleDetailPage: View {
    let circle: FriendCircle

    @Environment(CircleStore.self) private var circleStore
    @Environment(FriendStore.self) private var friendStore
    @Environment(UserProfileStore.self) private var userProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var policy: BookingPolicy = .permissive
    @State private var isSaving = false
    @State private var showingDeleteConfirm = false
    @State private var actionError: String?
    /// Nil until the circle's stored values have been loaded into the fields, so
    /// a snapshot arriving mid-edit can't reset what the host is typing.
    @State private var loadedCircleID: String?

    private var friendIDs: [String] { friendStore.friendIDs }

    private var members: [String] {
        circleStore.memberIDs(of: circle.id ?? "", among: friendIDs)
    }

    private var hasChanges: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != circle.name || policy != circle.policy
    }

    var body: some View {
        Form {
            if let actionError {
                Section { InlineErrorLabel(message: actionError) }
            }

            Section("Name") {
                TextField("Circle name", text: $name)
                    .textInputAutocapitalization(.sentences)
            }

            BookingPolicyEditor(policy: $policy)

            Section("Who's in it") {
                if members.isEmpty {
                    Text("Nobody yet. Assign friends from your Friends list.")
                        .font(.caption)
                        .foregroundColor(.secondaryText)
                } else {
                    ForEach(members, id: \.self) { friendID in
                        HStack(spacing: 12) {
                            GeneratedAvatar(seed: friendID)
                            Text(userProfileStore.displayName(for: friendID) ?? "FreeBNB User")
                            Spacer()
                            if circleStore.membership(for: friendID)?.overridePolicy != nil {
                                Text("Custom rules")
                                    .font(.caption)
                                    .foregroundColor(.secondaryText)
                            }
                        }
                    }
                }
            }

            if circle.isDeletable {
                Section {
                    Button("Delete circle", role: .destructive) { showingDeleteConfirm = true }
                } footer: {
                    Text("Anyone in it moves to \(circleStore.defaultCircle?.name ?? "your default circle").")
                }
            } else {
                Section {
                    EmptyView()
                } footer: {
                    // The one thing about Default that is not editable, said
                    // once, where a host would look for the delete button.
                    Text("This circle can't be deleted — new friends land here, so there always has to be one. Everything else about it, its name and all of its rules, is yours to change.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle(circle.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!hasChanges || !policy.isValid || isSaving)
            }
        }
        .onAppear {
            guard loadedCircleID != circle.id else { return }
            loadedCircleID = circle.id
            name = circle.name
            policy = circle.policy
        }
        .confirmationDialog("Delete \(circle.name)?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        }
        .disabled(isSaving)
    }

    private func save() async {
        isSaving = true
        actionError = nil
        defer { isSaving = false }
        do {
            try await circleStore.rename(circle, to: name)
            if policy != circle.policy {
                try await circleStore.updatePolicy(of: circle, to: policy, friendIDs: friendIDs)
            }
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete() async {
        isSaving = true
        actionError = nil
        defer { isSaving = false }
        do {
            try await circleStore.delete(circle, friendIDs: friendIDs)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

// MARK: - One friend

/// Which circle a friend is in, and the policy the host can set on them
/// directly. The override is presented as what it is — a rule for this one
/// person that wins over their circle's — and clearing it hands them back.
struct FriendCirclePage: View {
    let friendID: String
    let friendName: String

    @Environment(CircleStore.self) private var circleStore
    @Environment(FriendStore.self) private var friendStore

    @State private var overridePolicy: BookingPolicy?
    @State private var isSaving = false
    @State private var actionError: String?
    @State private var loadedFriendID: String?

    private var resolved: (policy: BookingPolicy, source: CirclePolicyResolver.Source) {
        circleStore.resolved(for: friendID)
    }

    private var currentCircleID: String {
        let stored = circleStore.membership(for: friendID)?.circleID ?? FriendCircle.defaultID
        return circleStore.circle(id: stored) == nil ? FriendCircle.defaultID : stored
    }

    private var overrideBinding: Binding<Bool> {
        Binding(
            get: { overridePolicy != nil },
            // Starts from whatever governs them today, so turning it on is a
            // place to edit from rather than a reset to permissive.
            set: { on in
                overridePolicy = on ? (circleStore.circle(id: currentCircleID)?.policy ?? .permissive) : nil
            }
        )
    }

    var body: some View {
        Form {
            if let actionError {
                Section { InlineErrorLabel(message: actionError) }
            }

            Section {
                ForEach(circleStore.circles) { circle in
                    Button {
                        Task { await assign(to: circle.id ?? FriendCircle.defaultID) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(circle.name).foregroundColor(.primary)
                                Text(bookingPolicySummary(circle.policy))
                                    .font(.caption)
                                    .foregroundColor(.secondaryText)
                            }
                            Spacer()
                            if circle.id == currentCircleID {
                                Image(systemName: "checkmark").foregroundColor(Color.accent)
                            }
                        }
                    }
                }
            } header: {
                Text("Circle")
            } footer: {
                Text("\(friendName) is never told which circle they're in, or that circles exist.")
            }

            Section {
                Toggle("Custom rules for \(friendName)", isOn: overrideBinding)
            } footer: {
                Text(overridePolicy == nil
                     ? "They follow their circle's rules."
                     : "These replace their circle's rules for as long as they're on. Turn them off to hand \(friendName) back to their circle.")
            }

            if overridePolicy != nil {
                BookingPolicyEditor(policy: Binding(
                    get: { overridePolicy ?? .permissive },
                    set: { overridePolicy = $0 }
                ))
            }

            // Below the rules, because that is the order a host actually works
            // in: they come here to change what somebody can book, and the notes
            // are what reminds them why. Nothing above reads them — moving
            // someone between circles stays a decision the host makes.
            Section {
                FriendNotesLink(friendID: friendID, friendName: friendName)
            } footer: {
                Text("Notes are yours alone. They don't change \(friendName)'s circle or their rules on their own.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.primaryBackground.ignoresSafeArea())
        .navigationTitle(friendName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await saveOverride() } }
                    .disabled(isSaving || !(overridePolicy?.isValid ?? true) || !overrideChanged)
            }
        }
        .onAppear {
            guard loadedFriendID != friendID else { return }
            loadedFriendID = friendID
            overridePolicy = circleStore.membership(for: friendID)?.overridePolicy
        }
        .task { await circleStore.reconcile(friendIDs: friendStore.friendIDs) }
        .disabled(isSaving)
    }

    private var overrideChanged: Bool {
        overridePolicy != circleStore.membership(for: friendID)?.overridePolicy
    }

    private func assign(to circleID: String) async {
        actionError = nil
        do { try await circleStore.assign(friendID: friendID, to: circleID) }
        catch { actionError = error.localizedDescription }
    }

    private func saveOverride() async {
        isSaving = true
        actionError = nil
        defer { isSaving = false }
        do { try await circleStore.setOverride(overridePolicy, forFriendID: friendID) }
        catch { actionError = error.localizedDescription }
    }
}

#Preview {
    NavigationStack {
        CirclesPage()
            .previewEnvironment()
    }
}
