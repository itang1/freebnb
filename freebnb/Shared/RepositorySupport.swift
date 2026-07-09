//
//  RepositorySupport.swift
//  freebnb
//
//  Cross-cutting helpers shared by every Firestore repository: logging, the
//  listener-cancellation protocol, the write-batch cap, and the transient-error
//  retry wrapper. Split out of the former monolithic Repositories.swift (A2).
//

@preconcurrency import FirebaseFirestore
import Foundation
import os

// MARK: - Logging

enum AppLog {
    static let subsystem = "com.freebnb.app"
    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}

// Shared by the repository files (each split into its own file), so it is
// module-internal rather than file-private.
let repoLog = AppLog.logger("repository")

// Firestore caps a WriteBatch at 500 operations.
let firestoreBatchLimit = 500

// MARK: - Listener cancellation

protocol RepositoryListener: Sendable {
    func cancel()
}

struct NoopListener: RepositoryListener {
    func cancel() {}
}

final class FirestoreListenerBox: RepositoryListener, @unchecked Sendable {
    private let inner: ListenerRegistration
    init(_ inner: ListenerRegistration) { self.inner = inner }
    func cancel() { inner.remove() }
}

/// Cancels several underlying listeners as a single unit.
struct CompositeListener: RepositoryListener {
    let listeners: [RepositoryListener]
    func cancel() { listeners.forEach { $0.cancel() } }
}

// MARK: - Retry helper

/// Retries `operation` up to `maxAttempts` times using exponential backoff
/// with full jitter. Only retries on transient Firestore errors (unavailable,
/// deadline exceeded, internal, resource exhausted). Gives up immediately on
/// permission errors or other unrecoverable failures.
func withRetry<T>(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 0.5,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var attempt = 0
    while true {
        do {
            return try await operation()
        } catch {
            attempt += 1
            let isTransient = isTransientFirestoreError(error)
            guard isTransient && attempt < maxAttempts else { throw error }
            let cap = baseDelay * pow(2.0, Double(attempt - 1))
            let jitter = Double.random(in: 0...cap)
            try await Task.sleep(nanoseconds: UInt64(jitter * 1_000_000_000))
        }
    }
}

private func isTransientFirestoreError(_ error: Error) -> Bool {
    let nsErr = error as NSError
    // Firestore error codes that indicate a transient condition:
    // 14 = unavailable, 4 = deadline exceeded, 13 = internal, 8 = resource exhausted
    let transientCodes: Set<Int> = [4, 8, 13, 14]
    if nsErr.domain == "FIRFirestoreErrorDomain" {
        return transientCodes.contains(nsErr.code)
    }
    // Also catch NSURLErrorNetworkConnectionLost and similar URLSession errors.
    if nsErr.domain == NSURLErrorDomain {
        return [NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut,
                NSURLErrorNotConnectedToInternet].contains(nsErr.code)
    }
    return false
}
