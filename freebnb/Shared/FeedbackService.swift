//
//  FeedbackService.swift
//  freebnb
//
//  In-app feedback (feature 43) is delivered to a Google Form whose responses
//  feed a spreadsheet the team reads directly, so there is no server or console
//  to check. The same Form is public on the web, so anyone can leave feedback
//  without the app; the native composer just posts to it silently.
//

import Foundation

/// The Google Form that collects feedback. These are the only values to touch if
/// the Form changes: rebuilding a question in the Form editor mints a new
/// `entry.<id>`, which the "Get pre-filled link" option reveals. The responses
/// land in the linked spreadsheet.
enum FeedbackForm {
    // swiftlint:disable force_unwrapping
    /// The unlisted endpoint that records a response. Distinct from `webURL`,
    /// which shows the fillable form.
    static let responseURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLScebr16uJz2NtsozI_y5fRcx-f0c51RDb2QjFcq0OBLJMELbw/formResponse")!
    /// The public, fillable form, for sharing outside the app and as the in-app
    /// fallback when a post fails.
    static let webURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLScebr16uJz2NtsozI_y5fRcx-f0c51RDb2QjFcq0OBLJMELbw/viewform")!
    // swiftlint:enable force_unwrapping

    /// The paragraph question: the feedback itself.
    static let messageField = "entry.1192119170"
    /// Short-answer, hidden from web users: who sent it, for follow-up.
    static let userIDField = "entry.1837812556"
    /// Short-answer, hidden from web users: the build the note came from.
    static let versionField = "entry.788164007"
}

/// Sends a feedback note somewhere the team can read it. An abstraction so the
/// store's submit path stays testable without a live network call.
protocol FeedbackService: Sendable {
    func submit(message: String, userID: String?, appVersion: String?) async throws
}

/// Posts a feedback note to `FeedbackForm` as an `x-www-form-urlencoded` body,
/// exactly as the fillable form would. The endpoint is unauthenticated and
/// unofficial, so a full account is not required; the composer still gates
/// guests as a product choice, and the browser form is the fallback if a post
/// fails.
struct GoogleFormFeedbackService: FeedbackService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum SubmitError: LocalizedError {
        case badResponse

        var errorDescription: String? {
            "We couldn't send your feedback just now. Check your connection and try again."
        }
    }

    func submit(message: String, userID: String?, appVersion: String?) async throws {
        var fields: [(String, String)] = [(FeedbackForm.messageField, message)]
        if let userID { fields.append((FeedbackForm.userIDField, userID)) }
        if let appVersion { fields.append((FeedbackForm.versionField, appVersion)) }

        // Encode each value against the RFC 3986 unreserved set so a '+' in the
        // note survives as a literal plus rather than being read as a space.
        let body = fields
            .map { "\($0.0)=\(Self.formEncode($0.1))" }
            .joined(separator: "&")

        var request = URLRequest(url: FeedbackForm.responseURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubmitError.badResponse
        }
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
