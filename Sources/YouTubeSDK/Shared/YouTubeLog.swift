import Foundation
#if canImport(os)
import os
#endif

public enum YouTubeLog {
    public enum Level: Int, Comparable {
        case trace = 0
        case debug = 1
        case info = 2
        case warning = 3
        case error = 4

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public nonisolated(unsafe) static var minLevel: Level = {
        #if DEBUG
        return .trace
        #else
        return .info
        #endif
    }()

    @inlinable public static func trace(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(message(), level: .trace, file: file, function: function, line: line)
    }

    @inlinable public static func debug(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(message(), level: .debug, file: file, function: function, line: line)
    }

    @inlinable public static func info(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(message(), level: .info, file: file, function: function, line: line)
    }

    @inlinable public static func warning(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(message(), level: .warning, file: file, function: function, line: line)
    }

    @inlinable public static func error(_ message: @autoclosure () -> String, file: String = #fileID, function: String = #function, line: Int = #line) {
        log(message(), level: .error, file: file, function: function, line: line)
    }


    @usableFromInline static func log(_ message: @autoclosure () -> String, level: Level, file: String, function: String, line: Int) {
        guard level >= minLevel else { return }
        let fileName = (file as NSString).lastPathComponent
        let text = "[\(fileName):\(line) \(function)] \(message())"
        #if canImport(os)
        // The unified log rather than stdout: `print` never reaches Console.app or `log show`.
        // Messages are written to keep URLs and tokens out, so they are logged as public.
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "cisum", category: "YouTubeSDK")
        switch level {
        case .trace, .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.notice("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        #else
        print(text)
        #endif
    }
}

#if !canImport(os)
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    
    public func notice(_ message: String) { print("[NOTICE] \(message)") }
    public func warning(_ message: String) { print("[WARNING] \(message)") }
    public func error(_ message: String) { print("[ERROR] \(message)") }
    public func info(_ message: String) { print("[INFO] \(message)") }
    public func debug(_ message: String) { print("[DEBUG] \(message)") }
    public func trace(_ message: String) { print("[TRACE] \(message)") }
    public func fault(_ message: String) { print("[FAULT] \(message)") }
}
#endif
