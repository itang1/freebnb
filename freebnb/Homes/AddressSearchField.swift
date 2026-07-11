//
//  AddressSearchField.swift
//  freebnb
//
//  Street field with MapKit autocomplete. Selecting a suggestion fills
//  street, city, state, and zip automatically.
//

import MapKit
import SwiftUI

struct AddressSearchField: View {
    @Binding var street: String
    @Binding var city: String
    @Binding var state: String
    @Binding var zip: String

    @State private var completer = AddressCompleter()
    @State private var showSuggestions = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            TextField("Street", text: $street)
                .textContentType(.streetAddressLine1)
                .focused($focused)
                .onChange(of: street) { _, newValue in
                    completer.search(newValue)
                    showSuggestions = focused && !newValue.isEmpty
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { showSuggestions = false }
                }

            if showSuggestions && !completer.suggestions.isEmpty {
                ForEach(completer.suggestions, id: \.self) { suggestion in
                    Button {
                        apply(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            TextField("City", text: $city)
                .textContentType(.addressCity)
            TextField("State", text: $state)
                .textContentType(.addressState)
            TextField("ZIP", text: $zip)
                .textContentType(.postalCode)
                .keyboardType(.numbersAndPunctuation)
        }
    }

    private func apply(_ completion: MKLocalSearchCompletion) {
        showSuggestions = false
        focused = false
        Task {
            let request = MKLocalSearch.Request(completion: completion)
            let response = try? await MKLocalSearch(request: request).start()
            guard let placemark = response?.mapItems.first?.placemark else {
                // The completion may name a place the search can no longer
                // resolve; keep at least the title so the host isn't left with
                // an empty field after tapping a suggestion.
                street = completion.title
                return
            }
            street = [placemark.subThoroughfare, placemark.thoroughfare]
                .compactMap { $0 }.joined(separator: " ")
            city   = placemark.locality ?? ""
            state  = placemark.administrativeArea ?? ""
            zip    = placemark.postalCode ?? ""
        }
    }
}

// MARK: - Completer

// MKLocalSearchCompleter delivers delegate callbacks on the main queue, and the
// only caller is a view. Pinning to @MainActor makes that contract explicit,
// matching AppleSignInCoordinator.
@MainActor
@Observable
private final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private let completer: MKLocalSearchCompleter
    private(set) var suggestions: [MKLocalSearchCompletion] = []

    override init() {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.resultTypes = .address
        completer.delegate = self
    }

    func search(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            suggestions = []
        } else {
            completer.queryFragment = trimmed
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            suggestions = Array(completer.results.prefix(5))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError _: Error) {
        MainActor.assumeIsolated {
            suggestions = []
        }
    }
}

#Preview {
    @Previewable @State var street = ""
    @Previewable @State var city = ""
    @Previewable @State var state = ""
    @Previewable @State var zip = ""
    Form {
        AddressSearchField(street: $street, city: $city, state: $state, zip: $zip)
    }
}
