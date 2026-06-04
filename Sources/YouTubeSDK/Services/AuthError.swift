import Foundation

// MARK: - AuthError

public enum AuthError: LocalizedError {
    case cancelled
    case missingCode
    case tokenExchangeFailed
    case notSignedIn
    case configurationError
    case deviceCodeRequestFailed
    case authorizationPending
    case slowDown
    case deviceCodeExpired
    case unknownError(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled"
        case .missingCode: "OAuth code was missing from callback"
        case .tokenExchangeFailed: "Failed to exchange code for tokens"
        case .notSignedIn: "You are not signed in"
        case .configurationError: "OAuth credentials could not be obtained"
        case .deviceCodeRequestFailed: "Could not start sign-in. Check your internet connection."
        case .authorizationPending: "Waiting for authorisation…"
        case .slowDown: "Too many requests — slowing down"
        case .deviceCodeExpired: "The sign-in code expired. Please try again."
        case let .unknownError(msg): msg
        }
    }
}
