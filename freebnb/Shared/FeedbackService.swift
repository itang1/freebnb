//
//  FeedbackService.swift
//  freebnb
//
//  In-app feedback goes to a Google Form whose responses feed a spreadsheet the team reads;
//  the same Form is public on the web, and the native composer just posts to it silently.
//

import Foundation

/// The Google Form that collects feedback. Rebuilding a question mints a new `entry.<id>`
/// ("Get pre-filled link" reveals it); these are the only values to touch.
enum FeedbackForm {
    // swiftlint:disable force_unwrapping
    /// The unlisted endpoint that records a response, distinct from `webURL`.
    static let responseURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLScebr16uJz2NtsozI_y5fRcx-f0c51RDb2QjFcq0OBLJMELbw/formResponse")!
    /// The public form, for sharing and as the fallback when a post fails.
    static let webURL = URL(string: "https://docs.google.com/forms/d/e/1FAIpQLScebr16uJz2NtsozI_y5fRcx-f0c51RDb2QjFcq0OBLJMELbw/viewform")!
    // swiftlint:enable force_unwrapping

    /// The paragraph question: the feedback itself.
    static let messageField = "entry.1192119170"
    /// Short-answer, hidden from web users: who sent it, for follow-up.
    static let userIDField = "entry.1837812556"
    /// Short-answer, hidden from web users: the build the note came from.
    static let versionField = "entry.788164007"
}

/// Sends a feedback note somewhere the team can read it; an abstraction so submit stays testable offline.
protocol FeedbackService: Sendable {
    func submit(message: String, userID: String?, appVersion: String?) async throws
}

/// Posts a note to `FeedbackForm` as an `x-www-form-urlencoded` body, like the fillable form.
/// The endpoint is unauthenticated and unofficial; the composer gates guests as a product
/// choice, and the web form is the fallback if a post fails.
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

        // Encode against the RFC 3986 unreserved set so a '+' survives as a plus, not a space.
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
