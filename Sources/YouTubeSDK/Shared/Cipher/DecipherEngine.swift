//
//  DecipherEngine.swift
//  YouTubeSDK
//
//  COMMENTED OUT: The decipher engine is not currently needed — all streams
//  return direct URLs with cipher=nil and no 'n' parameter.
//  SmartTubeIOS does not use a decipher engine.
//  Re-enable if YouTube re-introduces cipher-protected URLs.
//

/*
 import Foundation
 import JavaScriptCore

 class DecipherEngine {
     private let context = JSContext()!
     private var script: String = ""
     private var sigFn: JSValue?
     private var nFn: JSValue?
     private var evalContext: JSContext?

     func loadCipherScript(_ script: String) {
         self.script = script
         let ctx = JSContext()!
         ctx.exceptionHandler = { _, exc in
             if let e = exc { YouTubeLog.debug("DECIPHER ENGINE: JS exception: \(e)") }
         }
         self.evalContext = ctx
         YouTubeLog.debug("DECIPHER ENGINE: Loading script of length \(script.count)...")

         // Strategy 1: Individual function extraction with dependency extraction
         sigFn = extractFunctionWithDeps(named: findSigFuncName())
         nFn = extractFunctionWithDeps(named: findNFuncName())

         // If sigFn found but nFn is nil, the same function often handles both
         if sigFn != nil && nFn == nil {
             YouTubeLog.debug("DECIPHER ENGINE: Using sigFn for nFn (same function)")
             nFn = sigFn
         }

         // Strategy 2: URL constructor approach (fallback)
         if sigFn == nil && nFn == nil {
             YouTubeLog.debug("DECIPHER ENGINE: Trying URL constructor approach...")
             context.exceptionHandler = { _, e in
                 if let exc = e { YouTubeLog.debug("DECIPHER ENGINE: JS exception: \(exc)") }
             }
             // Evaluate full script so global scope has all functions
             context.evaluateScript(script)
             sigFn = discoverFnInContext()
             nFn = sigFn // URL ctor handles both
         }

         if sigFn == nil && nFn == nil {
             YouTubeLog.debug("DECIPHER ENGINE: WARNING - No decipher functions found")
         }
         YouTubeLog.debug("DECIPHER ENGINE: Ready - sigFn=\(sigFn?.isObject == true ? "yes" : "no") nFn=\(nFn?.isObject == true ? "yes" : "no")")
     }

     // MARK: - Individual Function Extraction (Primary)

     private let builtins: Set<String> = [
         "if", "for", "while", "switch", "catch", "typeof", "return",
         "var", "let", "const", "function", "else", "in", "of", "new",
         "delete", "void", "throw", "this", "instanceof", "try", "do",
         "break", "continue", "case", "default", "finally", "export",
         "import", "class", "extends", "super", "yield", "await", "async",
         "Date", "Math", "String", "Number", "Boolean", "Array", "Object",
         "RegExp", "Error", "Symbol", "Map", "Set", "Promise", "JSON",
         "parseInt", "parseFloat", "isNaN", "isFinite", "undefined", "null",
         "true", "false", "NaN", "Infinity", "console", "window", "globalThis",
         "encodeURI", "encodeURIComponent", "decodeURI", "decodeURIComponent",
         "Int8Array", "Uint8Array", "Int16Array", "Uint16Array", "Int32Array",
         "Uint32Array", "Float32Array", "Float64Array", "BigInt64Array",
         "BigUint64Array", "BigInt"
     ]

     private func extractFunctionWithDeps(named name: String?) -> JSValue? {
         guard let name = name, let ctx = evalContext else { return nil }

         var extracted = Set<String>()
         var toExtract = [name]
         var maxIter = 20

         while !toExtract.isEmpty && maxIter > 0 {
             maxIter -= 1
             let current = toExtract.removeLast()
             guard extracted.insert(current).inserted else { continue }

             guard let def = extractRawFunctionDef(named: current) else {
                 YouTubeLog.debug("DECIPHER ENGINE: Could not extract '\(current)' from source")
                 continue
             }

             ctx.evaluateScript("var \(current) = \(def);")

             let fnVal = ctx.objectForKeyedSubscript(current)
             if fnVal?.isUndefined == true {
                 YouTubeLog.debug("DECIPHER ENGINE: WARNING - '\(current)' still undefined after eval")
             }

             let deps = findCalledFunctions(in: def, owner: current, known: extracted)
             if !deps.isEmpty {
                 YouTubeLog.debug("DECIPHER ENGINE: '\(current)' deps found: \(deps.joined(separator: ","))")
             }
             for dep in deps {
                 if !extracted.contains(dep) && !toExtract.contains(dep) {
                     toExtract.append(dep)
                 }
             }
         }

         let fn = ctx.objectForKeyedSubscript(name)
         if fn?.isObject == true {
             let fnLen = fn?.forProperty("length")?.toInt32() ?? 0
             YouTubeLog.debug("DECIPHER ENGINE: Extracted '\(name)' (arity=\(fnLen)) with \(extracted.count - 1) dependencies")
             if let name2 = findSigFuncName() { YouTubeLog.debug("DECIPHER ENGINE: sig candidate = '\(name2)'") }
             if let name2 = findNFuncName() { YouTubeLog.debug("DECIPHER ENGINE: n candidate = '\(name2)'") }
             return fn
         }
         YouTubeLog.debug("DECIPHER ENGINE: Failed to extract '\(name)' after eval")
         return nil
     }

     private func findCalledFunctions(in body: String, owner: String, known: Set<String>) -> [String] {
         let nsBody = body as NSString
         let ownerParams = extractParamNames(from: body)
         var found: Set<String> = []

         // Regex: identifier( but NOT .identifier(
         let pattern = "(?<!\\.)\\b([a-zA-Z_$][a-zA-Z0-9_$]*)\\s*\\("
         guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

         regex.enumerateMatches(in: body, range: NSRange(location: 0, length: nsBody.length)) { match, _, _ in
             guard let m = match, m.numberOfRanges > 1 else { return }
             let name = nsBody.substring(with: m.range(at: 1))
             if !builtins.contains(name)
                 && !name.hasPrefix("__")
                 && !known.contains(name)
                 && !ownerParams.contains(name)
                 && name.utf8.count <= 3
             {
                 found.insert(name)
             }
         }

         return Array(found)
     }

     // MARK: - Raw Source Extraction

     private func extractRawFunctionDef(named name: String) -> String? {
         let nsSource = script as NSString
         let escapedName = NSRegularExpression.escapedPattern(for: name)
         let pattern = "(?:^|[^a-zA-Z0-9_$])\(escapedName)\\s*=\\s*function\\s*\\("
         guard let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: script, range: NSRange(location: 0, length: nsSource.length))
         else { return nil }

         let fnStart = match.range.location
         var i = match.range.location + match.range.length - 1
         var braceCount = 0
         var inString = false
         var stringChar: unichar = 0

         while i < nsSource.length {
             let c = nsSource.character(at: i)
             if inString {
                 if c == 92 { i += 2; continue }
                 if c == stringChar { inString = false }
             } else {
                 if c == 34 || c == 39 || c == 96 { inString = true; stringChar = c }
                 else if c == 123 { braceCount += 1 }
                 else if c == 125 {
                     braceCount -= 1
                     if braceCount == 0 {
                         let raw = nsSource.substring(with: NSRange(location: fnStart, length: i - fnStart + 1))
                         return stripToFunctionExpr(raw)
                     }
                 }
             }
             i += 1
         }
         return nil
     }

     private func stripToFunctionExpr(_ raw: String) -> String? {
         guard let range = raw.range(of: "function") else { return nil }
         return String(raw[range.lowerBound...])
     }

     private func extractParamNames(from funcDef: String) -> Set<String> {
         guard let open = funcDef.firstIndex(of: "("),
               let close = funcDef.firstIndex(of: ")"),
               open < close
         else { return [] }
         let params = funcDef[funcDef.index(after: open)..<close]
         let names = params.split(separator: ",").map {
             $0.trimmingCharacters(in: .whitespaces).components(separatedBy: "=").first!
                 .trimmingCharacters(in: .whitespaces)
         }
         return Set(names)
     }

     // MARK: - Candidate Name Discovery

     private func findSigFuncName() -> String? {
         let nsScript = script as NSString
         let patterns = [
             #"(?:\b|[^a-zA-Z0-9_$])([a-zA-Z0-9_$]{2,3})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)"#,
             #"([a-zA-Z0-9_$]+)\s*=\s*function\(\s*[a-zA-Z0-9_$]+\s*\)\s*\{\s*var\s+[a-zA-Z0-9_$]+\s*=\s*[a-zA-Z0-9_$]+\.split\(\s*""\s*\)"#,
             #"([a-zA-Z0-9_$]+)=\s*function\s*\(\s*[a-zA-Z0-9_$]+\s*\)\s*\{[^}]*\breturn\b[^}]+\.join\(\s*""\s*\)"#,
         ]
         return findFirst(patterns: patterns, nsScript: nsScript)
     }

     private func findNFuncName() -> String? {
         let nsScript = script as NSString
         let patterns = [
             #"(?:\.get\(["']n["']\)&&)?b=([a-zA-Z0-9_$]+)(?:\[[\d]+\])?\([a-zA-Z0-9_$]+\)"#,
             #"\.n=([a-zA-Z0-9_$]+)\([a-zA-Z0-9_$]+\.n\)"#,
             #"b=([a-zA-Z0-9_$]+)\([a-zA-Z0-9_$]+\[["']n["\']\]\)"#,
             #"([a-zA-Z0-9_$]+)=function\([a-zA-Z0-9_$]+\)\{var [a-zA-Z0-9_$]+=a\.split\(""#"#,
             #"(?:\b|[^a-zA-Z0-9_$])([a-zA-Z0-9_$]{2,3})\s*=\s*function\(\s*a\s*\)\s*\{\s*a\s*=\s*a\.split\(\s*""\s*\)"#,
             #"function\s+([a-zA-Z0-9_$]+)\s*\(\s*[a-zA-Z0-9_$]+\s*\)\s*\{[^}]*\breturn\b[^}]+\.join\(\s*""\s*\)"#,
             #"([a-zA-Z0-9_$]{1,3})=function\(a\)\{a=a\.split\(""#"#,
         ]
         return findFirst(patterns: patterns, nsScript: nsScript)
     }

     private func findFirst(patterns: [String], nsScript: NSString) -> String? {
         for pattern in patterns {
             guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
             for match in regex.matches(in: script as String, range: NSRange(location: 0, length: nsScript.length)) {
                 if match.numberOfRanges > 1 {
                     return nsScript.substring(with: match.range(at: 1))
                 }
             }
         }
         return nil
     }

     // MARK: - URL Constructor Discovery (Eval Full Script)

     private func discoverFnInContext() -> JSValue? {
         YouTubeLog.debug("DECIPHER ENGINE: Searching for URL constructor in JS context...")
         let searchJS = """
         (function() {
             function looksLikeUrlCtor(fn) {
                 try {
                     if (typeof fn !== 'function' || fn.length < 3) return false;
                     var str = fn.toString();
                     if (str.indexOf('.set(') === -1) return false;
                     if (str.indexOf('new ') === -1) return false;
                     if (str.indexOf('alr') === -1) return false;
                     return true;
                 } catch(e) { return false; }
             }
             var checked = new Set();
             function search(obj, depth) {
                 if (depth > 2) return null;
                 if (!obj || typeof obj !== 'object') return null;
                 try {
                     var keys = Object.getOwnPropertyNames(obj);
                     for (var i = 0; i < keys.length; i++) {
                         var k = keys[i];
                         if (checked.has(k)) continue;
                         checked.add(k);
                         try {
                             var v = obj[k];
                             if (typeof v === 'function' && looksLikeUrlCtor(v)) return v;
                             if (typeof v === 'object' && v !== null) {
                                 var found = search(v, depth + 1);
                                 if (found) return found;
                             }
                         } catch(e) {}
                     }
                 } catch(e) {}
                 return null;
             }
             return search(this, 0) || search(globalThis || this, 0) || null;
         })()
         """
         guard let fn = context.evaluateScript(searchJS), fn.isObject else {
             YouTubeLog.debug("DECIPHER ENGINE: No URL constructor found in context")
             return nil
         }
         YouTubeLog.debug("DECIPHER ENGINE: Found URL constructor in context")
         return fn
     }

     // MARK: - Decipher

     func decipher(signature: String) -> String {
         if let fn = sigFn {
             let result = fn.call(withArguments: [signature])
             if let str = result?.toString(), !str.isEmpty, str != "undefined" {
                 YouTubeLog.debug("DECIPHER ENGINE: Sig deciphered (len \(str.count))")
                 return str
             }
             YouTubeLog.debug("DECIPHER ENGINE: Sig fn returned invalid: \(result?.toString() ?? "nil")")
         }
         YouTubeLog.debug("DECIPHER ENGINE: Sig strategies failed, returning original (len \(signature.count))")
         return signature
     }

     func decipherN(nValue: String) -> String {
         if let fn = nFn {
             let result = fn.call(withArguments: [nValue])
             if let str = result?.toString(), !str.isEmpty, str != "undefined" {
                 YouTubeLog.debug("DECIPHER ENGINE: 'n' deciphered (len \(str.count))")
                 return str
             }
             YouTubeLog.debug("DECIPHER ENGINE: 'n' fn returned invalid: \(result?.toString() ?? "nil")")
         }
         YouTubeLog.debug("DECIPHER ENGINE: 'n' strategies failed, returning original (len \(nValue.count))")
         return nValue
     }
 }
 */
