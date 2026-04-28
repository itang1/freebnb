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
        // Resolve the completion to a full placemark to get city/state/zip.
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            guard let placemark = response?.mapItems.first?.placemark else {
                // Fallback: parse what we can from the completion strings.
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

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = Array(completer.results.prefix(5))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError _: Error) {
        suggestions = []
    }
}
