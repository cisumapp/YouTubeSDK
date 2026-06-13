#if canImport(Android)
import Foundation
import SwiftJavaJNICore

// Helper: Convert a JNI jstring to a Swift String
private func jniStringToSwift(_ env: UnsafeMutablePointer<JNIEnv?>, _ jstr: jstring?) -> String? {
    guard let jstr = jstr else { return nil }
    guard let chars = env.pointee?.pointee.GetStringUTFChars(env, jstr, nil) else { return nil }
    let swift = String(cString: chars)
    env.pointee?.pointee.ReleaseStringUTFChars(env, jstr, chars)
    return swift
}

// Helper: Convert a Swift String to a JNI jstring
private func swiftStringToJni(_ env: UnsafeMutablePointer<JNIEnv?>, _ str: String) -> jstring? {
    return env.pointee?.pointee.NewStringUTF(env, str)
}

// MARK: - Search

@_cdecl("Java_aaravgupta_cisum_swift_YouTube_nativeSearch")
func jni_search(
    _ env: UnsafeMutablePointer<JNIEnv?>!,
    _ thisObj: jobject!,
    _ query: jstring!
) -> jstring? {
    guard let env = env else { return nil }
    guard let queryStr = jniStringToSwift(env, query) else { return nil }

    // For now, return a JSON array to prove the bridge works
    // We'll wire up the real YouTubeMusicClient later
    let result = """
    [{"id":"test-1","title":"Bridge test: \(queryStr)","artist":"Swift on Android"}]
    """
    return swiftStringToJni(env, result)
}

#endif
