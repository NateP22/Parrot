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
        var localBindings: Set<String> = []
        var definitionBindings: Set<String> = []
    }
    struct FileCoverage {
        let supported: Bool
        var navigationComplete: Bool
        var loaderInventoryComplete: Bool
        var discoveredDeclarations: Int
        var discoveredEvalSites: Int
        var reasons: [String]
        var declarationInventoryComplete: Bool
        var incompleteExecutableSpans: [ClosedRange<Int>] = []
    }
    struct Limits {
        var navigationDeclarations = 256
        var inventoryDeclarations = 2048
        var scanBytes = 8 * 1024 * 1024
        var spanBytes = 128 * 1024
        var spanLines = 512
    }
    let source: RepositoryKnowledge
    let passages: [RepositoryKnowledge.Passage]
    let declarations: [Declaration]
    /// Separate bounded inventory recovers late loader declarations even when
    /// ordinary navigation's first256 declarations have been retained already.
    let loaderDeclarations: [Declaration]
    let declarationInventory: [Declaration]
    let globalNamespaces: [Int: Set<String>]
    let localBindings: [Int: Set<String>]
    let fileCoverage: [Int: FileCoverage]
    private let lines: [[String]]
    private let finalNewlines: [Bool]
    private let fileIndices: [String: Int]
    private let definitions: [String: [Int]]

    init(source: RepositoryKnowledge, passages: [RepositoryKnowledge.Passage], limits: Limits = .init()) {
        self.source = source
        self.passages = passages
        var allLines: [[String]] = [], endings: [Bool] = [], found: [Declaration] = [], loaders: [Declaration] = []
        var coverage: [Int: FileCoverage] = [:], globals: [Int: Set<String>] = [:]
        var locals: [Int: Set<String>] = [:]
        var inventory: [Declaration] = []
        for (i, file) in source.files.enumerated() {
            let final = file.text.utf8.last == 10
            var split = file.text.components(separatedBy: "\n")
            if final { split.removeLast() }
            allLines.append(split); endings.append(final)
            let parsed = Self.declarations(in: file, fileIndex: i, limits: limits)
            var status = parsed.coverage
            let retained = Array(parsed.navigation.prefix(max(0, 6000 - found.count)))
            if retained.count != parsed.navigation.count { status.navigationComplete = false; status.reasons.append("repository-navigation-cap") }
            found += retained
            loaders += parsed.loaders
            let retainedInventory = Array(parsed.inventory.prefix(max(0, 20_000 - inventory.count)))
            if retainedInventory.count != parsed.inventory.count { status.declarationInventoryComplete = false; status.reasons.append("repository-declaration-inventory-cap") }
            inventory += retainedInventory
            globals[i] = parsed.globals
            locals[i] = parsed.locals
            coverage[i] = status
        }
        lines = allLines; finalNewlines = endings; declarations = found
        loaderDeclarations = loaders; fileCoverage = coverage
        declarationInventory = inventory; globalNamespaces = globals
        localBindings = locals
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

    func passage(file index: Int, start: Int, end: Int) -> RepositoryKnowledge.Passage {
        let file = source.files[index]
        let text = lines[index][(start - 1)..<end].joined(separator: "\n")
            + (end < lines[index].count || finalNewlines[index] ? "\n" : "")
        return .init(text: text, citation: .init(repository: source.repository, commit: source.commit,
            path: file.path, blob: file.blob, sha256: file.sha256, startLine: start, endLine: end, revision: source.revision))
    }

    func wholeFile(_ index: Int) -> RepositoryKnowledge.Passage {
        passage(file: index, start: 1, end: lines[index].count)
    }

    func owners(overlapping citation: RepositoryCitation) -> [Int] {
        guard let file = fileIndices[citation.path] else { return [] }
        return declarationInventory.indices.filter {
            let node = declarationInventory[$0]
            return node.file == file && node.startLine <= citation.endLine && node.endLine >= citation.startLine
        }
    }

    func coalesced(_ nodes: Set<Int>, role: String) -> [RepositoryKnowledge.Passage] {
        var output: [RepositoryKnowledge.Passage] = []
        for file in Set(nodes.map { declarationInventory[$0].file }).sorted() {
            let spans = nodes.map { declarationInventory[$0] }.filter { $0.file == file }.sorted { $0.startLine < $1.startLine }
            var ranges: [(Int, Int)] = []
            for span in spans {
                if let last = ranges.last {
                    let gap = span.startLine > last.1 + 1 ? lines[file][last.1..<(span.startLine - 1)].joined(separator: "\n") : ""
                    if span.startLine <= last.1 + 1 || (span.startLine - last.1 <= 4 && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                        ranges[ranges.count - 1] = (last.0, max(last.1, span.endLine)); continue
                    }
                }
                ranges.append((span.startLine, span.endLine))
            }
            for range in ranges { var p = passage(file: file, start: range.0, end: range.1); p.contextRole = role; output.append(p) }
        }
        return output
    }

    private static func declarations(in file: RepositoryKnowledge.File, fileIndex: Int, limits: Limits)
        -> (navigation: [Declaration], loaders: [Declaration], inventory: [Declaration], globals: Set<String>, locals: Set<String>, coverage: FileCoverage) {
        // Conservative C-style declarations only. Other languages/mixed JSX
        // retain original lexical windows; no invented language semantics.
        let unsupported = FileCoverage(supported: false, navigationComplete: false, loaderInventoryComplete: false,
            discoveredDeclarations: 0, discoveredEvalSites: 0, reasons: ["unsupported-static-adapter"], declarationInventoryComplete: false)
        guard ["js", "mjs", "cjs", "jsx", "jsxinc", "ts"].contains((file.path as NSString).pathExtension.lowercased()) else { return ([], [], [], [], [], unsupported) }
        let masked = maskLiteralsAndComments(Array(file.text.utf8))
        let string = String(decoding: masked, as: UTF8.self) as NSString
        // React/JSX markup is outside this conservative scanner's language.
        // ExtendScript .jsx without markup remains ordinary JavaScript.
        guard (string as String).range(of: #"<[A-Za-z][A-Za-z0-9.:_-]*(?:\s[^>]*|/?)>"#, options: .regularExpression) == nil else { return ([], [], [], [], [], unsupported) }
        let pattern = #"\bfunction\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^{};]*\)|\b([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)\s*=\s*(?:async\s+)?function\s*\([^{};]*\)|\bfunc\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^{};]*\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let callRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$.])([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)\s*\("#),
              let evalRegex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9_$.])\$\.evalFile\s*\("#) else { return ([], [], [], [], [], unsupported) }
        // Only explicit top-level source declarations establish a namespace
        // owner. An IIFE-local R or a coincidental short spelling cannot make
        // a cross-file edge. Dynamic/export-alias binding remains unsupported.
        let globalRegex = try! NSRegularExpression(pattern: #"\b(?:var|let|const|class|function)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#)
        let globalMatches = globalRegex.matches(in: string as String, range: NSRange(location: 0, length: string.length))
        var globalNames = Set<String>(), localNames = Set<String>(), cursor = 0, braceDepth = 0
        for match in globalMatches {
            while cursor < match.range.location { if masked[cursor] == 123 { braceDepth += 1 }; if masked[cursor] == 125 { braceDepth = max(0, braceDepth - 1) }; cursor += 1 }
            if braceDepth == 0 { globalNames.insert(string.substring(with: match.range(at: 1))) }
            else { localNames.insert(string.substring(with: match.range(at: 1))) }
        }
        // Brace pairs are inventory-only: even an oversized anonymous IIFE can
        // establish an ancestor binding without claiming its whole body fits.
        var stack: [Int] = [], closes: [Int: Int] = [:]
        for i in masked.indices { if masked[i] == 123 { stack.append(i) }; if masked[i] == 125, let start = stack.popLast() { closes[start] = i + 1 } }
        struct LexicalScope { let start: Int; let end: Int; var names: Set<String> }
        let scopeRegex = try! NSRegularExpression(pattern: #"\bfunction(?:\s+[A-Za-z_$][A-Za-z0-9_$]*)?\s*\(([^{};]*)\)"#)
        let scopeMatches = scopeRegex.matches(in: string as String, range: NSRange(location: 0, length: string.length))
        var lexical: [LexicalScope] = []
        let parameterRegex = try! NSRegularExpression(pattern: #"(?:^|,)\s*(?:\.\.\.)?([A-Za-z_$][A-Za-z0-9_$]*)"#)
        for match in scopeMatches.prefix(4096) {
            guard let start = functionBody(masked, after: match.range.location + match.range.length), let end = closes[start] else { continue }
            let params = string.substring(with: match.range(at: 1)) as NSString
            let names = parameterRegex.matches(in: params as String, range: NSRange(location: 0, length: params.length)).map { params.substring(with: $0.range(at: 1)) }
            lexical.append(.init(start: start, end: end, names: Set(names)))
        }
        for binding in globalMatches {
            let candidates = lexical.indices.filter { lexical[$0].start < binding.range.location && lexical[$0].end > binding.range.location }
            if let nearest = candidates.max(by: { lexical[$0].start < lexical[$1].start }) { lexical[nearest].names.insert(string.substring(with: binding.range(at: 1))) }
        }
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
        let inventoryLimit = max(1, min(2048, limits.inventoryDeclarations))
        regex.enumerateMatches(in: string as String, range: NSRange(location: 0, length: string.length)) { match, _, stop in
            if let match { matches.append(match) }
            if matches.count > inventoryLimit { stop.pointee = true }
        }
        var status = FileCoverage(supported: true, navigationComplete: true, loaderInventoryComplete: true,
            discoveredDeclarations: matches.count, discoveredEvalSites: 0, reasons: [], declarationInventoryComplete: true)
        // These executable forms are deliberately NOT parsed by this adapter.
        // Masked comments/strings cannot create unsupported-syntax signals.
        if (string as String).contains("=>") { status.reasons.append("unsupported-arrow-function") }
        if (string as String).range(of: #"(?<![A-Za-z0-9_$.])class\b"#, options: .regularExpression) != nil { status.reasons.append("unsupported-class-method-syntax") }
        let methodRegex = try! NSRegularExpression(pattern: #"(?:^|[{},;])\s*(?:async\s+)?(?:(?:get|set)\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^{};]*\)\s*\{"#)
        let controls: Set<String> = ["if", "for", "while", "switch", "catch", "with", "function"]
        if methodRegex.matches(in: string as String, range: NSRange(location: 0, length: string.length)).contains(where: { !controls.contains(string.substring(with: $0.range(at: 1))) }) { status.reasons.append("unsupported-concise-method-syntax") }
        if !status.reasons.isEmpty { status.navigationComplete = false; status.declarationInventoryComplete = false }
        if matches.count > inventoryLimit { status.navigationComplete = false; status.declarationInventoryComplete = false; status.reasons.append("declaration-inventory-cap") }
        if scopeMatches.count > 4096 { status.declarationInventoryComplete = false; status.reasons.append("lexical-scope-inventory-cap") }
        let navLimit = max(1, min(256, limits.navigationDeclarations))
        if matches.count > navLimit { status.navigationComplete = false; status.reasons.append("navigation-declaration-cap") }
        var evalSites: [Int] = []
        evalRegex.enumerateMatches(in: string as String, range: NSRange(location: 0, length: string.length)) { match, _, stop in
            if let match { evalSites.append(match.range.location) }
            if evalSites.count > 4096 { stop.pointee = true }
        }
        status.discoveredEvalSites = evalSites.count
        if evalSites.count > 4096 { status.loaderInventoryComplete = false; status.reasons.append("eval-site-inventory-cap") }
        var scanBudget = max(0, min(8 * 1024 * 1024, limits.scanBytes))
        var navigation: [Declaration] = [], loaders: [Declaration] = [], inventory: [Declaration] = [], coveredEvalSites = Set<Int>()
        for (ordinal, match) in matches.prefix(inventoryLimit).enumerated() {
            let nameRange = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
            guard let open = functionBody(masked, after: match.range.location + match.range.length) else {
                status.navigationComplete = false; status.declarationInventoryComplete = false; status.reasons.append("unsupported-function-header"); continue
            }
            var depth = 1, end = open + 1
            while end < masked.count && depth > 0 && end - open <= max(1, min(128 * 1024, limits.spanBytes)) && scanBudget > 0 {
                scanBudget -= 1
                if masked[end] == 123 { depth += 1 }
                if masked[end] == 125 { depth -= 1 }
                end += 1
            }
            guard depth == 0, line(at: end - 1) - line(at: match.range.location) <= max(1, min(512, limits.spanLines)) else {
                status.navigationComplete = false
                status.declarationInventoryComplete = false
                status.reasons.append(scanBudget == 0 ? "function-scan-budget" : "function-span-limit")
                if let completeEnd = closes[open] { status.incompleteExecutableSpans.append(line(at: match.range.location)...line(at: completeEnd - 1)) }
                continue
            }
            let body = NSRange(location: open + 1, length: end - open - 2)
            let reserved: Set<String> = ["if", "for", "while", "switch", "catch", "function", "with"]
            var calls = Set<String>()
            let children = lexical.filter { $0.start > open && $0.end < end }
            callRegex.enumerateMatches(in: string as String, range: body) { match, _, stop in
                if let match, !children.contains(where: { $0.start < match.range.location && $0.end > match.range.location }) { calls.insert(string.substring(with: match.range(at: 1))) }
                if calls.count >= 128 { stop.pointee = true }
            }
            calls.subtract(reserved)
            if calls.count >= 128 { status.navigationComplete = false; status.declarationInventoryComplete = false; status.reasons.append("call-name-cap") }
            let contained = evalSites.filter { $0 > open && $0 < end }
            if !contained.isEmpty { calls.insert("$.evalFile"); coveredEvalSites.formUnion(contained) }
            var bindings = Set<String>(), definitionBindings = Set<String>()
            for scope in lexical where scope.start <= open && scope.end >= end { bindings.formUnion(scope.names) }
            for scope in lexical where scope.start < open && scope.end >= end { definitionBindings.formUnion(scope.names) }
            if scopeMatches.count > 4096 { bindings.insert("*"); definitionBindings.insert("*") }
            let node = Declaration(file: fileIndex, name: string.substring(with: nameRange),
                startLine: line(at: match.range.location), endLine: line(at: end - 1), calls: calls, localBindings: bindings, definitionBindings: definitionBindings)
            if ordinal < navLimit { navigation.append(node) }
            inventory.append(node)
            if !contained.isEmpty { loaders.append(node) }
        }
        if !Set(evalSites).isSubset(of: coveredEvalSites) { status.loaderInventoryComplete = false; status.reasons.append("uncovered-eval-site") }
        status.reasons = Array(Set(status.reasons)).sorted()
        return (navigation, loaders, inventory, globalNames, localNames, status)
    }

    /// Supported JS/TS headers only. A balanced inline object/generic return
    /// type is skipped before locating the REAL executable body. Conditional
    /// or function-type ambiguity is explicitly unsupported, never a type-only
    /// block falsely labelled a complete function.
    private static func functionBody(_ b: [UInt8], after: Int) -> Int? {
        var i = after; while i < b.count && b[i] <= 32 { i += 1 }
        if i < b.count && b[i] == 123 { return i }
        guard i < b.count && b[i] == 58 else { return nil }; i += 1
        var angles = 0, brackets = 0, parens = 0, typeBraces = 0, hasType = false, previous: UInt8 = 0
        while i < b.count && i - after <= 16 * 1024 {
            let c = b[i]
            if c <= 32 { i += 1; continue }
            if typeBraces == 0 && (c == 63 || (c == 61 && i + 1 < b.count && b[i + 1] == 62)) { return nil }
            if c == 123 {
                if typeBraces > 0 || angles > 0 || brackets > 0 || parens > 0 || !hasType || previous == 38 || previous == 124 { typeBraces += 1 }
                else { return i }
            } else if c == 125 { guard typeBraces > 0 else { return nil }; typeBraces -= 1 }
            else if c == 60 { angles += 1 }
            else if c == 62 { guard angles > 0 else { return nil }; angles -= 1 }
            else if c == 91 { brackets += 1 }
            else if c == 93 { guard brackets > 0 else { return nil }; brackets -= 1 }
            else if c == 40 { parens += 1 }
            else if c == 41 { guard parens > 0 else { return nil }; parens -= 1 }
            else if c == 59 && typeBraces == 0 { return nil }
            hasType = true; previous = c; i += 1
        }
        return nil
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
