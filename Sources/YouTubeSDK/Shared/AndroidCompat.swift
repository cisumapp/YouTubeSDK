#if !canImport(Darwin)
import Foundation

// MARK: - XMLParser Compat
public protocol XMLParserDelegate: AnyObject {}

public class XMLParser {
    public weak var delegate: XMLParserDelegate?
    public init(data: Data) {}
    public func parse() -> Bool { return false }
}

// MARK: - iCloud Compat
public let NSUbiquitousKeyValueStoreChangedKeysKey = "NSUbiquitousKeyValueStoreChangedKeysKey"

public class NSUbiquitousKeyValueStore: @unchecked Sendable {
    public static let `default` = NSUbiquitousKeyValueStore()
    public static let didChangeExternallyNotification = Notification.Name("NSUbiquitousKeyValueStoreDidChangeExternally")
    
    public func data(forKey aKey: String) -> Data? { return nil }
    public func set(_ aData: Data?, forKey aKey: String) {}
    public func synchronize() -> Bool { return true }
}

public extension Notification.Name {
    static let NSUbiquityIdentityDidChange = Notification.Name("NSUbiquityIdentityDidChange")
}

public extension FileManager {
    var ubiquityIdentityToken: Any? { return nil }
}

#endif
