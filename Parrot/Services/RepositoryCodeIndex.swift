import Foundation

/// Local navigation hints over original code, not an execution graph or facts.
/// Declarations/call spellings help retain related guards. Dynamic dispatch,
/// templates and unsupported syntax still require review of the cited code.
/// Parsing happens once at import; questions never invoke a model or parser.
struct RepositoryCodeIndex {
    struct Declaration {
        let file: Int
        let name: String
        let startLine: Int
        let endLine: Int
        let calls: Set<String>
    }
    let source: RepositoryKnowledge
    let passages: [RepositoryKnowledge.Passage]
    let declarations: [Declaration]
    private let lines: [[String]]
    private let finalNewlines: [Bool]
    private let fileIndices: [String: Int]
    private let definitions: [String: [Int]]

    init(source: RepositoryKnowledge, passages: [RepositoryKnowledge.Passage]) {
        self.source = source
        self.passages = passages
        var allLines: [[String]] = [], endings: [Bool] = [], found: [Declaration] = []
        for (i, file) in source.files.enumerated() {
            let final = file.text.utf8.last == 10
            var split = file.text.components(separatedBy: "\n")
            if final { split.removeLast() }
            allLines.append(split); endings.append(final)
            if found.count < 6000 { found += Self.declarations(in: file, fileIndex: i).prefix(6000 - found.count) }
        }
        lines = allLines; finalNewlines = endings; declarations = found
        fileIndices = Dictionary(uniqueKeysWithValues: source.files.enumerated().map { ($0.element.path, $0.offset) })
        definitions = Dictionary(grouping: found.indices, by: { found[$0].name })
    }

    func primaryPassageIndices(scopeID: String?) -> [Int] {
        guard let scopeID, let scope = source.runtimeScopes?.first(where: { $0.id == scopeID }) else { return [] }
        return passages.indices.filter { scope.contains(passages[$0].citation.path) }
    }

    /// Complete bounded declaration spans precede related definitions/callers.
    /// Duplicate definitions are retained together; never choose an overload or
    /// a different runtime by score. If required spans cannot fit, return no
    /// evidence rather than silently amputating a function/exception branch.
    func expanded(seedIndices: [Int], scopeID: String?, limit: Int = 6,
                  maximumCharacters: Int = 32_000) -> [RepositoryKnowledge.Passage] {
        guard limit > 0, maximumCharacters > 0, let scopeID,
              let scope = source.runtimeScopes?.first(where: { $0.id == scopeID }) else { return [] }
        let seeds = seedIndices.filter { passages.indices.contains($0) && scope.contains(passages[$0].citation.path) }
        guard !seeds.isEmpty else { return [] }
        var selected: [Int] = [], fallback: [Int] = []
        for seed in seeds.prefix(2) {
            let citation = passages[seed].citation
            guard let file = fileIndices[citation.path] else { continue }
            let containing = declarations.indices.filter {
                declarations[$0].file == file && declarations[$0].startLine <= citation.endLine && declarations[$0].endLine >= citation.startLine
            }.sorted {
                let a = declarations[$0], b = declarations[$1]
                let overlapA = min(a.endLine, citation.endLine) - max(a.startLine, citation.startLine)
                let overlapB = min(b.endLine, citation.endLine) - max(b.startLine, citation.startLine)
                return overlapA == overlapB ? a.startLine < b.startLine : overlapA > overlapB
            }
            if let first = containing.first {
                if !selected.contains(first) { selected.append(first) }
            } else { fallback.append(seed) }
        }
        let primary = selected
        // One hop, scoped first. A same-file spelling has priority, but all
        // definitions of that spelling in that file remain alternatives.
        for index in primary {
            let declaration = declarations[index]
            for name in declaration.calls.sorted() {
                let allowed = (definitions[name] ?? []).filter {
                    scope.permitsDependency(source.files[declarations[$0].file].path)
                }
                let local = allowed.filter { declarations[$0].file == declaration.file }
                let matches = local.isEmpty ? allowed : local
                // Unrelated common call names can be very ambiguous. Do not
                // pick one arbitrary definition or let them crowd out seeds.
                guard matches.count <= 3 else { return [] }
                for match in matches where !selected.contains(match) { selected.append(match) }
            }
        }
        // Direct caller spellings are useful for flags configured outside a
        // callee. They are navigation hints, never proof of actual dispatch.
        var callers: [Int] = []
        for index in primary {
            let declaration = declarations[index]
            for candidate in declarations.indices where candidate != index &&
                scope.contains(source.files[declarations[candidate].file].path) &&
                declarations[candidate].calls.contains(declaration.name) && !selected.contains(candidate) {
                if callers.count < 64 { callers.append(candidate) }
            }
        }
        var output: [RepositoryKnowledge.Passage] = [], characters = 0
        for index in selected {
            let node = declarations[index]
            let passage = passage(file: node.file, start: node.startLine, end: node.endLine)
            if output.contains(where: { $0.citation == passage.citation }) { continue }
            guard output.count < limit, characters + passage.text.count <= maximumCharacters else { return [] }
            output.append(passage); characters += passage.text.count
        }
        for index in callers where output.count < limit {
            let node = declarations[index]
            let passage = passage(file: node.file, start: node.startLine, end: node.endLine)
            guard !output.contains(where: { $0.citation == passage.citation }),
                  characters + passage.text.count <= maximumCharacters else { continue }
            output.append(passage); characters += passage.text.count
        }
        for index in fallback + Array(seeds.dropFirst(2)) where output.count < limit {
            let passage = passages[index]
            guard !output.contains(where: { $0.citation.path == passage.citation.path &&
                $0.citation.startLine <= passage.citation.startLine && $0.citation.endLine >= passage.citation.endLine }),
                characters + passage.text.count <= maximumCharacters else { continue }
            output.append(passage); characters += passage.text.count
        }
        return output
    }

    private func passage(file index: Int, start: Int, end: Int) -> RepositoryKnowledge.Passage {
        let file = source.files[index]
        let text = lines[index][(start - 1)..<end].joined(separator: "\n")
            + (end < lines[index].count || finalNewlines[index] ? "\n" : "")
        return .init(text: text, citation: .init(repository: source.repository, commit: source.commit,
            path: file.path, blob: file.blob, sha256: file.sha256, startLine: start, endLine: end, revision: source.revision))
    }

    private static func declarations(in file: RepositoryKnowledge.File, fileIndex: Int) -> [Declaration] {
        // Conservative C-style declarations only. Other languages/mixed JSX
        // retain original lexical windows; no invented language semantics.
        guard ["js", "mjs", "cjs", "jsx", "jsxinc", "ts"].contains((file.path as NSString).pathExtension.lowercased()) else { return [] }
        let masked = maskLiteralsAndComments(Array(file.text.utf8))
        let string = String(decoding: masked, as: UTF8.self) as NSString
        // React/JSX markup is outside this conservative scanner's language.
        // ExtendScript .jsx without markup remains ordinary JavaScript.
        guard (string as String).range(of: #"<[A-Za-z][A-Za-z0-9.:_-]*(?:\s[^>]*|/?)>"#, options: .regularExpression) == nil else { return [] }
        let pattern = #"\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^{};]*\)\s*(?::[^{};]+)?\{|\b([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s+)?function\s*\([^{};]*\)\s*\{|\bfunc\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^{};]*\)[^{};]*\{"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let callRegex = try? NSRegularExpression(pattern: #"\b([A-Za-z_$][A-Za-z0-9_$]*)\s*\("#) else { return [] }
        // masked is ASCII (non-ASCII code bytes replaced with spaces), so
        // regex UTF16 offsets, byte positions and preserved newlines coincide.
        var newlineOffsets = [-1]
        for i in masked.indices where masked[i] == 10 { newlineOffsets.append(i) }
        func line(at offset: Int) -> Int {
            var lo = 0, hi = newlineOffsets.count
            while lo < hi { let mid = (lo + hi) / 2; if newlineOffsets[mid] < offset { lo = mid + 1 } else { hi = mid } }
            return max(1, lo)
        }
        var matches: [NSTextCheckingResult] = []
        regex.enumerateMatches(in: string as String, range: NSRange(location: 0, length: string.length)) { match, _, stop in
            if let match { matches.append(match) }
            if matches.count >= 256 { stop.pointee = true }
        }
        var scanBudget = 8 * 1024 * 1024
        return matches.compactMap { match in
            let nameRange = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            let open = match.range.location + match.range.length - 1
            var depth = 1, end = open + 1
            while end < masked.count && depth > 0 && end - open <= 128 * 1024 && scanBudget > 0 {
                scanBudget -= 1
                if masked[end] == 123 { depth += 1 }
                if masked[end] == 125 { depth -= 1 }
                end += 1
            }
            guard depth == 0, line(at: end - 1) - line(at: match.range.location) <= 512 else { return nil }
            let body = NSRange(location: open + 1, length: end - open - 2)
            let reserved: Set<String> = ["if", "for", "while", "switch", "catch", "function", "with"]
            var calls = Set<String>()
            callRegex.enumerateMatches(in: string as String, range: body) { match, _, stop in
                if let match { calls.insert(string.substring(with: match.range(at: 1))) }
                if calls.count >= 128 { stop.pointee = true }
            }
            calls.subtract(reserved)
            return Declaration(file: fileIndex, name: string.substring(with: nameRange),
                startLine: line(at: match.range.location), endLine: line(at: end - 1), calls: calls)
        }
    }

    /// Preserve offsets/newlines, ignore braces in comments/string/regex text.
    /// Template interpolations are deliberately opaque rather than guessed.
    private static func maskLiteralsAndComments(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes.map { $0 < 128 ? $0 : 32 }, i = 0, previous: UInt8 = 0
        func blank(_ n: Int) { if bytes[n] != 10 && bytes[n] != 13 { out[n] = 32 } }
        while i < bytes.count {
            let c = bytes[i], next = i + 1 < bytes.count ? bytes[i + 1] : 0
            if c == 47 && next == 47 {
                while i < bytes.count && bytes[i] != 10 { blank(i); i += 1 }; continue
            }
            if c == 47 && next == 42 {
                blank(i); blank(i + 1); i += 2
                while i < bytes.count {
                    if bytes[i] == 42 && i + 1 < bytes.count && bytes[i + 1] == 47 { blank(i); blank(i + 1); i += 2; break }
                    blank(i); i += 1
                }; continue
            }
            var before = ""
            if c == 47 {
                var wordEnd = i
                while wordEnd > 0 && bytes[wordEnd - 1] <= 32 { wordEnd -= 1 }
                var wordStart = wordEnd
                while wordStart > 0 && ((65...90).contains(bytes[wordStart - 1]) || (97...122).contains(bytes[wordStart - 1])) { wordStart -= 1 }
                before = String(decoding: bytes[wordStart..<wordEnd], as: UTF8.self)
            }
            let isRegex = c == 47 && (previous == 0 || [UInt8(61), 40, 91, 44, 58, 33, 38, 124, 63, 123, 59].contains(previous) || ["return", "throw", "yield", "case"].contains(before))
            if c == 34 || c == 39 || c == 96 || isRegex {
                let quote = c; blank(i); i += 1
                var inClass = false
                while i < bytes.count {
                    let b = bytes[i]; blank(i); i += 1
                    if b == 92 && i < bytes.count { blank(i); i += 1; continue }
                    if isRegex && b == 91 { inClass = true }
                    if isRegex && b == 93 { inClass = false }
                    if b == quote && !inClass { break }
                }
                previous = 65; continue
            }
            if c > 32 { previous = c }
            i += 1
        }
        return out
    }
}
