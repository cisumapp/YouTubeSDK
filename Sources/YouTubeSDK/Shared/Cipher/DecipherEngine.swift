//
//  DecipherEngine.swift
//  YouTubeSDK
//
//  Created by Aarav Gupta on 01/01/26.
//

import Foundation
import JavaScriptCore

class DecipherEngine {
    let context = JSContext()!
    
    private var decipherFunctionName: String?
    private var nFunctionName: String?
    
    /// Loads the script and prepares the environment
    func loadCipherScript(_ script: String) throws {
        print("DECIPHER ENGINE: Loading script of length \(script.count). Prefix: \(script.prefix(100))...")
        
        // 1. Evaluate the WHOLE script first (so all variables exist)
        // This puts 'base.js' into memory.
        context.evaluateScript(script)
        
        // 2. Find the Signature Decipher Function name
        let signaturePatterns = [
            #"([a-zA-Z0-9_$]+)\s*=\s*function\([a-zA-Z0-9_$]+\)\s*\{\s*[a-zA-Z0-9_$]+\s*=\s*[a-zA-Z0-9_$]+\.split\(""[\s\S]*?\}"#,
            #"([a-zA-Z0-9_$]+)\s*=\s*function\([a-zA-Z0-9_$]+\)\s*\{\s*[a-zA-Z0-9_$]+\s*=\s*[a-zA-Z0-9_$]+\.split\(""\)"#,
            #"\b([a-zA-Z0-9_$]{2,})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)"#,
            #"([a-zA-Z0-9_$]+)=function\([a-zA-Z0-9_$]+\)\{var [a-zA-Z0-9_$]+=a\.split\(""\);"#
        ]
        
        for pattern in signaturePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
               let range = Range(match.range(at: 1), in: script) {
                let functionName = String(script[range])
                self.decipherFunctionName = functionName
                print("DECIPHER ENGINE: Found signature function '\(functionName)'")
                break
            }
        }
        
        // 3. Find the 'n' Decipher Function name
        let nPatterns = [
            #"([a-zA-Z0-9_$]+)=function\([a-zA-Z0-9_$]+\)\{var [a-zA-Z0-9_$]+=a\.split\(""\),[a-zA-Z0-9_$]+=\[[^\]]+\]"#,
            #"\.n=([a-zA-Z0-9_$]+)\(a\.n\)"#,
            #"([a-zA-Z0-9_$]+)=function\([a-zA-Z0-9_$]+\)\{var [a-zA-Z0-9_$]+=a\.split\(""\);[a-zA-Z0-9_$]+=a\.split\(""\)"#,
            #"([a-zA-Z0-9_$]+)=function\([a-zA-Z0-9_$]+\)\{var [a-zA-Z0-9_$]+=a\.split\(""\)"#,
            #"([a-zA-Z0-9_$]+)=function\([a-zA-Z0-9_$]+\)\{var [a-zA-Z0-9_$]+=a\.split\(""\);"#
        ]
        
        for pattern in nPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.lastMatch(in: script, range: NSRange(script.startIndex..., in: script)),
               let range = Range(match.range(at: 1), in: script) {
                let functionName = String(script[range])
                // Ensure it's not the same as signature function if we found one
                if functionName != self.decipherFunctionName {
                    self.nFunctionName = functionName
                    print("DECIPHER ENGINE: Found 'n' function '\(functionName)'")
                    break
                }
            }
        }
        
        if decipherFunctionName == nil {
            print("DECIPHER ENGINE: WARNING - Couldn't find signature decipher function")
        }
        if nFunctionName == nil {
            print("DECIPHER ENGINE: WARNING - Couldn't find 'n' decipher function")
        }
        
        // Only throw if we found ABSOLUTELY nothing. 
        // If we found at least one, we can partially function.
        if decipherFunctionName == nil && nFunctionName == nil {
            print("DECIPHER ENGINE: CRITICAL - Failed to find both signature and 'n' functions")
            throw URLError(.resourceUnavailable)
        }

    }
    
    /// Unlocks a signature
    func decipher(signature: String) throws -> String {
        guard let functionName = decipherFunctionName else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let result = context.evaluateScript("\(functionName)('\(signature)')")
        
        if let decrypted = result?.toString(), !decrypted.isEmpty, decrypted != "undefined" {
            return decrypted
        } else {
            throw URLError(.cannotDecodeRawData)
        }
    }
    
    /// Unlocks an 'n' parameter
    func decipherN(nValue: String) throws -> String {
        guard let functionName = nFunctionName else {
            // If we didn't find the 'n' function, just return the original value.
            // Some players don't have it or use a different form.
            return nValue
        }
        
        let result = context.evaluateScript("\(functionName)('\(nValue)')")
        
        if let decrypted = result?.toString(), !decrypted.isEmpty, decrypted != "undefined" {
            return decrypted
        } else {
            return nValue
        }
    }
}

extension NSRegularExpression {
    func lastMatch(in string: String, range: NSRange) -> NSTextCheckingResult? {
        let matches = self.matches(in: string, range: range)
        return matches.last
    }
}
