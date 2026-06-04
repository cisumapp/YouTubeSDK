//
//  Keychain.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 30/12/25.
//

import Foundation
import Security

public enum Keychain {
    /// A namespace for your app so keys don't collide with other apps
    private static let serviceName = "aaravgupta.youtubesdk.security"

    /// Saves a string to the Keychain.
    /// - Parameters:
    ///   - value: The string to save (e.g., the cookie string).
    ///   - key: A unique identifier (e.g., "youtube_cookies").
    public static func save(_ value: String, key: String) {
        guard let data = value.data(using: .utf8) else { return }

        // 1. Create a query to identify the item
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]

        // 2. Delete any existing item with this key (simplest update strategy)
        SecItemDelete(query as CFDictionary)

        // 3. Add the new item
        let status = SecItemAdd(query as CFDictionary, nil)

        if status != errSecSuccess {
            print("⚠️ Keychain Save Error: \(status)")
        }
    }

    /// Retrieves a string from the Keychain.
    public static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true, // We want the data back
            kSecMatchLimit as String: kSecMatchLimitOne, // We only want one result
        ]

        var dataTypeRef: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        if status == errSecSuccess {
            if let data = dataTypeRef as? Data {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    /// Deletes an item from the Keychain.
    public static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
        ]

        SecItemDelete(query as CFDictionary)
    }
}
