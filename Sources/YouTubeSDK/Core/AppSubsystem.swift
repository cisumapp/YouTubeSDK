import Foundation

/// Logging subsystem string derived from the app's bundle identifier at runtime.
let appSubsystem: String = Bundle.main.bundleIdentifier ?? "com.void.smarttube.app"
