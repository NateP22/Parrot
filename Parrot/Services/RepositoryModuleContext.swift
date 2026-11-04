import Foundation

/// Import-time static navigation, not a runtime/deployment or execution graph.
/// Complete original spans remain evidence; strings and comments cannot make
/// loader edges. Unsupported adapters retain scoped declaration retrieval.
struct RepositoryModuleContext {
    struct Scope {
        var modules: Set<Int> = []
        var loaders: [Int: [Int]] = [:]
        var incomplete = false
        var unresolvedLoaders: [Int] = []
        var navigationIncompleteFiles = 0
        var loaderInventoryIncomplete = false
        var clientScripts: Set<Int> = []
        var scriptEvidence: [Int: [RepositoryKnowledge.Passage]] = [:]
        var htmlIssues: [String] = []
        var incompleteSupportedScans: [String: [String]] = [:]
    }
    struct Selection {
        let passages: [RepositoryKnowledge.Passage]
        var note: String
        var unresolvedLoaderCount = 0
        var navigationIncompleteFileCount = 0
        var omittedRelatedPaths: [String] = []
        var clientOwnerCount = 0
        var htmlIssueCount = 0
        var clientNavigationSkippedCount = 0
        var unverifiedClientOwnerCount = 0
        var omittedClientCallNames: [String] = []
        var incompleteSupportedScanPaths: [String: [String]] = [:]
        var partialSourcePaths: [String: [String]] = [:]
    }
    // Conservative local source budget below the768KiB serialized body ceiling.
    // Escaping, metadata, schema and changing suffix still require final-body
    // admission. This is NOT real token/account/native capacity proof.
    static let maximumBytes = 512 * 1024
    private let index: RepositoryCodeIndex
    private let scopes: [String: Scope]
    private let exports: [Int: Set<String>]
    private let calls: [Int: Set<String>]
    private let files: [String: Int]
    private let nodesByFile: [Int: [Int]]
    private let definitionsByFile: [Int: [String: [Int]]]
    private let globalDefinitions: [String: [Int]]

    func issue(for scopeID: String) -> String? {
        guard let scope = scopes[scopeID] else { return nil }
        if scope.loaderInventoryIncomplete { return "Source context on hold: bounded entrypoint loader inventory incomplete." }
        return scope.incomplete ? "Source context on hold: ambiguous, missing or dynamic declared loads." : nil
    }

    init(index: RepositoryCodeIndex) {
        self.index = index
        let fileLookup = Dictionary(uniqueKeysWithValues: index.source.files.enumerated().map { ($0.element.path, $0.offset) })
        files = fileLookup
        let grouped = Dictionary(grouping: index.declarationInventory, by: \.file)
        let positions = Dictionary(grouping: index.declarationInventory.indices, by: { index.declarationInventory[$0].file })
        nodesByFile = positions
        var localDefinitions: [Int: [String: [Int]]] = [:], globals: [String: [Int]] = [:]
        for (file, nodes) in positions {
            localDefinitions[file] = Dictionary(grouping: nodes, by: { index.declarationInventory[$0].name })
            for id in nodes {
                let name = index.declarationInventory[id].name
                if let root = name.split(separator: ".").first, name.contains("."), index.globalNamespaces[file]?.contains(String(root)) == true,
                   !index.declarationInventory[id].definitionBindings.contains(String(root)),
                   !index.declarationInventory[id].definitionBindings.contains("*") { globals[name, default: []].append(id) }
            }
        }
        definitionsByFile = localDefinitions; globalDefinitions = globals
        exports = grouped.mapValues { nodes in Set(nodes.filter { node in
            guard let root = node.name.split(separator: ".").first, node.name.contains(".") else { return false }
            return index.globalNamespaces[node.file]?.contains(String(root)) == true && !node.definitionBindings.contains(String(root)) && !node.definitionBindings.contains("*")
        }.map(\.name)) }
        calls = grouped.mapValues { Set($0.flatMap(\.calls)) }
        var built: [String: Scope] = [:]
        for scope in index.source.runtimeScopes ?? [] {
            var result = Scope()
            for file in index.source.files.indices where scope.permitsDependency(index.source.files[file].path) {
                if let coverage = index.fileCoverage[file], coverage.supported && !coverage.declarationInventoryComplete {
                    result.incompleteSupportedScans[index.source.files[file].path] = coverage.reasons
                }
            }
            result.navigationIncompleteFiles = index.source.files.indices.filter {
                scope.contains(index.source.files[$0].path) && index.fileCoverage[$0]?.navigationComplete != true
            }.count
            result.loaderInventoryIncomplete = scope.entryPoints.contains { path in
                guard let file = fileLookup[path], let status = index.fileCoverage[file] else { return true }
                return status.supported && !status.loaderInventoryComplete
            }
            for loader in index.loaderDeclarations.indices {
                let node = index.loaderDeclarations[loader]
                guard scope.entryPoints.contains(index.source.files[node.file].path), node.calls.contains("$.evalFile") else { continue }
                // Do not borrow another function's local variables/eval call.
                if index.loaderDeclarations.contains(where: { $0.file == node.file && $0.startLine > node.startLine && $0.endLine < node.endLine }) {
                    result.unresolvedLoaders.append(loader); continue
                }
                let parsed = Self.loadedNames(index.passage(file: node.file, start: node.startLine, end: node.endLine).text)
                guard parsed.recognized else { result.unresolvedLoaders.append(loader); continue }
                result.incomplete = result.incomplete || !parsed.complete
                for name in parsed.names {
                    let matches = index.source.files.indices.filter { scope.contains(index.source.files[$0].path) && (index.source.files[$0].path as NSString).lastPathComponent == name }
                    guard matches.count == 1 else { result.incomplete = true; continue }
                    result.modules.insert(matches[0]); result.loaders[matches[0], default: []].append(loader)
                }
            }
            if result.loaders.values.contains(where: { $0.count != 1 }) { result.incomplete = true }
            for html in index.source.files.indices where scope.entryPoints.contains(index.source.files[html].path) && (index.source.files[html].path as NSString).pathExtension.lowercased() == "html" {
                let parsed = Self.scriptSources(index.source.files[html].text)
                result.htmlIssues += parsed.issues.map { index.source.files[html].path + ": " + $0 }
                for script in parsed.sources {
                    guard let path = Self.scriptPath(script.path, relativeTo: index.source.files[html].path), scope.contains(path), let file = fileLookup[path] else {
                        result.htmlIssues.append(index.source.files[html].path + ": missing/out-of-scope/unsupported literal script source"); continue
                    }
                    result.clientScripts.insert(file)
                    let span = index.passage(file: html, start: script.startLine, end: script.endLine)
                    result.scriptEvidence[file, default: []].append(span)
                }
            }
            built[scope.id] = result
        }
        scopes = built
    }

    private static func scriptPath(_ value: String, relativeTo html: String) -> String? {
        let path = value.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? ""
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.contains("\\"), !path.contains("%"), !path.contains("&") else { return nil }
        var parts = html.components(separatedBy: "/"); parts.removeLast()
        for part in path.components(separatedBy: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(part) }
        }
        let normalized = parts.joined(separator: "/")
        return RepositoryKnowledge.permits(path: normalized) ? normalized : nil
    }

    /// Literal HTML only: quote-aware tag boundaries, comments and raw script
    /// bodies are skipped. This is declared script ownership, not browser
    /// execution or an ES-module/dynamic-import dependency graph.
    private static func scriptSources(_ text: String) -> (sources: [(path: String, startLine: Int, endLine: Int)], issues: [String]) {
        let b = Array(text.utf8), lower = Array(text.utf8).map { (65...90).contains($0) ? $0 + 32 : $0 }
        var i = 0, tags = 0, output: [(String, Int, Int)] = [], issues: [String] = []
        func starts(_ position: Int, _ value: String) -> Bool { let bytes = Array(value.utf8); return position >= 0 && position + bytes.count <= lower.count && Array(lower[position..<(position + bytes.count)]) == bytes }
        func find(_ value: String, from: Int) -> Int? { var at = from; while at < b.count { if starts(at, value) { return at }; at += 1 }; return nil }
        func line(_ at: Int) -> Int { b.prefix(at).filter { $0 == 10 }.count + 1 }
        while i < b.count && tags < 8192 && output.count < 128 {
            guard b[i] == 60 else { i += 1; continue }
            if starts(i, "<!--") { guard let end = find("-->", from: i + 4) else { issues.append("unterminated HTML comment"); break }; i = end + 3; continue }
            let start = i; tags += 1; var end = i + 1, quote: UInt8 = 0
            while end < b.count {
                let c = b[end]
                if quote != 0 { if c == quote { quote = 0 } }
                else if c == 34 || c == 39 { quote = c }
                else if c == 62 { break }
                end += 1
            }
            guard end < b.count else { issues.append("unterminated HTML tag"); break }
            let isScript = starts(start, "<script") && start + 7 < b.count && (b[start + 7] <= 32 || b[start + 7] == 62)
            if isScript {
                var cursor = start + 7, sources: [String] = [], invalid = false
                while cursor < end {
                    while cursor < end && b[cursor] <= 32 { cursor += 1 }; if cursor >= end { break }
                    let nameStart = cursor
                    while cursor < end && b[cursor] > 32 && ![UInt8(61), 47, 62].contains(b[cursor]) { cursor += 1 }
                    if cursor == nameStart { cursor += 1; continue }
                    let name = String(decoding: lower[nameStart..<cursor], as: UTF8.self)
                    while cursor < end && b[cursor] <= 32 { cursor += 1 }
                    guard cursor < end && b[cursor] == 61 else { if name == "src" { invalid = true }; continue }
                    cursor += 1; while cursor < end && b[cursor] <= 32 { cursor += 1 }
                    guard cursor < end && (b[cursor] == 34 || b[cursor] == 39) else {
                        if name == "src" { invalid = true }; while cursor < end && b[cursor] > 32 { cursor += 1 }; continue
                    }
                    let q = b[cursor]; cursor += 1; let valueStart = cursor
                    while cursor < end && b[cursor] != q { cursor += 1 }
                    if name == "src" { sources.append(String(decoding: b[valueStart..<cursor], as: UTF8.self)) }
                    if cursor < end { cursor += 1 }
                }
                if sources.count == 1 && !invalid { output.append((sources[0], line(start), line(end))) }
                else if !sources.isEmpty || invalid { issues.append("ambiguous/nonliteral script src") }
                guard let close = find("</script", from: end + 1), let closeEnd = find(">", from: close) else { issues.append("unterminated script element"); break }
                i = closeEnd + 1
            } else { i = end + 1 }
        }
        if i < b.count && (tags >= 8192 || output.count >= 128) { issues.append("HTML script inventory cap") }
        return (output, issues)
    }

    func select(seeds: [Int], scopeID: String?, limit: Int = 32, maximumBytes: Int = Self.maximumBytes) -> Selection {
        guard let scopeID, let scope = scopes[scopeID] else { return .init(passages: [], note: "Source context on hold: explicit runtime required.") }
        func scoped(_ value: Selection) -> Selection {
            var result = value
            result.unresolvedLoaderCount = scope.unresolvedLoaders.count
            result.navigationIncompleteFileCount = scope.navigationIncompleteFiles
            result.htmlIssueCount = scope.htmlIssues.count
            result.incompleteSupportedScanPaths = scope.incompleteSupportedScans
            for path in Set(value.passages.map { $0.citation.path }) {
                guard let reasons = scope.incompleteSupportedScans[path], let file = files[path] else { continue }
                let wholeProvided = value.passages.contains { $0.citation.path == path && $0.citation.startLine == 1 && $0.text == index.source.files[file].text }
                if !wholeProvided { result.partialSourcePaths[path] = reasons }
            }
            if !scope.incompleteSupportedScans.isEmpty {
                let paths = scope.incompleteSupportedScans.keys.sorted().map { $0 + " [" + scope.incompleteSupportedScans[$0]!.joined(separator: ",") + "]" }
                result.note += " Supported scan inventories incomplete: " + paths.joined(separator: "; ") + ". Bounded discovered related set is not exhaustive; unknown callers/guards may exist. This is not evidence of absence or runtime completeness. If the requested condition depends on missing behavior, use needs_check."
            }
            if !result.partialSourcePaths.isEmpty {
                result.note += " Provided source text remains partial for: " + result.partialSourcePaths.keys.sorted().joined(separator: ", ") + ". If the requested condition depends on missing behavior, use needs_check."
            }
            return result
        }
        guard limit > 0, maximumBytes > 0 else { return scoped(.init(passages: [], note: "Source context on hold: positive source/reference budget required.")) }
        guard !scope.loaderInventoryIncomplete else { return scoped(.init(passages: [], note: "Source context on hold: bounded entrypoint loader inventory incomplete; discovered counts do not bound unseen loaders.")) }
        guard !scope.incomplete else { return scoped(.init(passages: [], note: "Source context on hold: ambiguous, missing or dynamic declared loads.")) }
        let runtime = index.source.runtimeScopes!.first { $0.id == scopeID }!
        let seeds = seeds.filter { index.passages.indices.contains($0) && runtime.contains(index.passages[$0].citation.path) }
        let inventoryNote = " Host evalFile inventory is host-loader-only, not client/runtime completeness. Counts are discovered within supported bounded scans, not a complete runtime/call graph. Navigation incomplete/unsupported files: \(scope.navigationIncompleteFiles). Literal HTML script-src mapping issues: \(scope.htmlIssues.count); ES-module and dynamic-import adapters are not proved."
        func fallback(_ reason: String) -> Selection {
            scoped(.init(passages: index.expanded(seedIndices: seeds, scopeID: scopeID, limit: limit, maximumCharacters: min(32_000, maximumBytes)), note: reason + " Separate unresolved loader routines: \(scope.unresolvedLoaders.count); dispatch, path and override behavior remain unverified." + inventoryNote))
        }
        var selectedPrimary: Int?
        for seed in seeds.prefix(32) {
            let citation = index.passages[seed].citation
            // Do not skip a better-ranked unresolved lazy-loader declaration
            // and pretend a weaker loaded module proves its dispatch behavior.
            if scope.unresolvedLoaders.contains(where: { id in
                let node = index.loaderDeclarations[id]
                return index.source.files[node.file].path == citation.path && node.startLine <= citation.endLine && node.endLine >= citation.startLine
            }) { return fallback("Question-leading entrypoint dispatch is unresolved; retain complete declaration evidence.") }
            if let file = files[citation.path], scope.modules.contains(file), (nodesByFile[file] ?? []).contains(where: { index.declarationInventory[$0].name.contains(".") }) { selectedPrimary = file; break }
        }
        guard let primary = selectedPrimary else {
            return fallback("Bounded complete declarations; module and dispatch completeness unverified.")
        }
        // Browser scripts and host globals are distinct execution contexts.
        // Literal HTML ownership does not turn a browser's local/global name
        // into an ExtendScript global with the same spelling.
        var allowed = scope.modules
        let hostLoaderFiles = Set(index.loaderDeclarations.map(\.file))
        for (path, file) in files where ((runtime.entryPoints.contains(path) && hostLoaderFiles.contains(file)) || (!runtime.contains(path) && runtime.permitsDependency(path))) && !scope.clientScripts.contains(file) { allowed.insert(file) }
        func crossDefinitions(_ name: String, caller: RepositoryCodeIndex.Declaration) -> [Int] {
            guard name.contains("."), let root = name.split(separator: ".").first,
                  !caller.localBindings.contains(String(root)), !caller.localBindings.contains("*") else { return [] }
            return (globalDefinitions[name] ?? []).filter { allowed.contains(index.declarationInventory[$0].file) }
        }
        func closure(_ initial: Set<Int>) -> Set<Int>? {
            var found = initial, queue = Array(initial), position = 0
            while position < queue.count {
                let id = queue[position]; position += 1; let node = index.declarationInventory[id]
                for name in node.calls {
                    // Every same-file spelling alternative is retained; never
                    // choose an IIFE-local R/helper by lexical path or score.
                    for candidate in definitionsByFile[node.file]?[name] ?? [] where found.insert(candidate).inserted { queue.append(candidate) }
                }
                if found.count > 512 { return nil }
            }
            return found
        }
        // Whole primary remains broad evidence, but dependency nomination is
        // anchored to actual ranked owning declarations, never every export
        // in that module. All same-file alternatives/guards stay together.
        var rankedPrimary = Set<Int>()
        for seed in seeds.prefix(32) where index.passages[seed].citation.path == index.source.files[primary].path {
            rankedPrimary.formUnion(index.owners(overlapping: index.passages[seed].citation))
            if !rankedPrimary.isEmpty { break }
        }
        guard let primaryClosure = closure(rankedPrimary), !primaryClosure.isEmpty else {
            return fallback("Ranked primary executable owner unresolved; whole-module exports are not a relevance substitute.")
        }
        let primaryNames = Set(primaryClosure.map { index.declarationInventory[$0].name }).intersection(exports[primary] ?? [])
        var needed = Set<Int>()
        for (file, nodes) in nodesByFile where allowed.contains(file) && file != primary {
            for id in nodes {
                let node = index.declarationInventory[id]
                if node.calls.contains(where: { primaryNames.contains($0) && crossDefinitions($0, caller: node).contains(where: { index.declarationInventory[$0].file == primary }) }) { needed.insert(id) }
            }
        }
        for id in primaryClosure {
            let node = index.declarationInventory[id]
            for name in node.calls { needed.formUnion(crossDefinitions(name, caller: node).filter { index.declarationInventory[$0].file != primary }) }
        }
        guard let completeRelated = closure(needed) else { return scoped(.init(passages: [], note: "Source context on hold: complete same-file related declaration closure exceeds bound." + inventoryNote)) }
        let relatedFiles = Set(completeRelated.map { index.declarationInventory[$0].file }).filter { $0 != primary }
        let sparseRelated = index.coalesced(Set(completeRelated.filter { index.declarationInventory[$0].file != primary }), role: "related_declarations")
        // Preserve actually ranked client owner functions, including declarations
        // recovered beyond navigation256. HTML alone never proves client code.
        var clientNodes = Set<Int>(), ui: [RepositoryKnowledge.Passage] = []
        var navigationSkipped = 0, unverifiedClientOwners = 0, omittedClientCalls = Set<String>()
        if let html = seeds.map({ index.passages[$0] }).first(where: { ($0.citation.path as NSString).pathExtension.lowercased() == "html" && $0.text.utf8.count <= 8192 }) { var p = html; p.contextRole = "ui"; ui.append(p) }
        for seed in seeds.prefix(8) {
            let citation = index.passages[seed].citation
            guard let file = files[citation.path], scope.clientScripts.contains(file) else { continue }
            let owners = index.owners(overlapping: citation)
            if owners.isEmpty {
                let incomplete = index.fileCoverage[file]?.incompleteExecutableSpans.contains { $0.overlaps(citation.startLine...citation.endLine) } == true
                if incomplete { unverifiedClientOwners += 1 } else { navigationSkipped += 1 }
                continue
            }
            clientNodes.formUnion(owners)
            for evidence in scope.scriptEvidence[file] ?? [] where !ui.contains(where: { $0.citation.path == evidence.citation.path && $0.citation.startLine <= evidence.citation.startLine && $0.citation.endLine >= evidence.citation.endLine }) { var p = evidence; p.contextRole = "ui"; ui.append(p) }
        }
        // The executable owner and ALL direct same-file guard/helper spellings
        // are one unit. Do not recursively drag an event-registration tree into
        // optional UI context. Report deeper callable omissions explicitly.
        var directClient = clientNodes
        for id in clientNodes {
            let node = index.declarationInventory[id]
            for name in node.calls { directClient.formUnion(definitionsByFile[node.file]?[name] ?? []) }
        }
        for id in directClient.subtracting(clientNodes) {
            let node = index.declarationInventory[id]
            for name in node.calls where (definitionsByFile[node.file]?[name] ?? []).contains(where: { !directClient.contains($0) }) { omittedClientCalls.insert(name) }
        }
        let clientSpans = index.coalesced(directClient, role: "ui")
        if directClient.count <= 32 && clientSpans.reduce(0, { $0 + $1.text.utf8.count }) <= 64 * 1024 && clientSpans.count <= 4 {
            ui += clientSpans
        } else {
            unverifiedClientOwners += clientNodes.count
            for id in clientNodes { omittedClientCalls.formUnion(index.declarationInventory[id].calls) }
            let owners = index.coalesced(clientNodes, role: "ui")
            if owners.count <= 4 && owners.reduce(0, { $0 + $1.text.utf8.count }) <= 64 * 1024 { ui += owners }
        }
        let loaderIDs = scope.loaders[primary] ?? []
        var base = loaderIDs.map { id -> RepositoryKnowledge.Passage in
            let node = index.loaderDeclarations[id]; var span = index.passage(file: node.file, start: node.startLine, end: node.endLine); span.contextRole = "loader"; return span
        }
        var primarySpan = index.wholeFile(primary); primarySpan.contextRole = "module"
        base.insert(primarySpan, at: 0)
        guard base.count <= limit, base.reduce(0, { $0 + $1.text.utf8.count }) <= maximumBytes else { return fallback("Bounded complete declarations; whole primary module exceeds source budget.") }
        for file in relatedFiles {
            for id in scope.loaders[file] ?? [] {
                let node = index.loaderDeclarations[id]; var loader = index.passage(file: node.file, start: node.startLine, end: node.endLine); loader.contextRole = "loader"
                if !base.contains(where: { $0.citation == loader.citation }) { base.append(loader) }
            }
        }
        func fits(_ spans: [RepositoryKnowledge.Passage]) -> Bool { spans.count <= limit && spans.reduce(0, { $0 + $1.text.utf8.count }) <= maximumBytes }
        // Required sparse evidence is never displaced by an optional upgrade.
        // Cheap whole-file upgrades can also consolidate references before a
        // reference-budget HOLD; a large entrypoint cannot block other files.
        var output = base + sparseRelated
        let partialParticipating = Set(output.compactMap { span -> Int? in scope.incompleteSupportedScans[span.citation.path] == nil ? nil : files[span.citation.path] }).subtracting([primary])
        let upgrades = Set(relatedFiles).union(partialParticipating).sorted { a, b in
            func cost(_ file: Int) -> Int { index.source.files[file].text.utf8.count - sparseRelated.filter { $0.citation.path == index.source.files[file].path }.reduce(0) { $0 + $1.text.utf8.count } }
            let ac = cost(a), bc = cost(b)
            return ac == bc ? index.source.files[a].path < index.source.files[b].path : ac < bc
        }
        for file in upgrades {
            let path = index.source.files[file].path
            var whole = index.wholeFile(file); whole.contextRole = "module"
            let candidate = output.filter { $0.citation.path != path || $0.contextRole == "loader" } + [whole]
            let bytesFit = candidate.reduce(0) { $0 + $1.text.utf8.count } <= maximumBytes
            if bytesFit && (candidate.count <= limit || candidate.count < output.count) { output = candidate }
        }
        // A partial client scan gets the same whole-text opportunity within
        // its smaller optional-UI bounds; it remains question-varying UI.
        for path in Set(ui.map { $0.citation.path }).sorted() where scope.incompleteSupportedScans[path] != nil {
            guard let file = files[path] else { continue }
            var whole = index.wholeFile(file); whole.contextRole = "ui"
            let candidate = ui.filter { $0.citation.path != path } + [whole]
            if candidate.count <= 4 && candidate.reduce(0, { $0 + $1.text.utf8.count }) <= 64 * 1024 && fits(output + candidate) { ui = candidate }
        }
        guard fits(output) else {
            let omissions = relatedFiles.map { index.source.files[$0].path }.sorted()
            return scoped(.init(passages: [], note: "Source context on hold: exact provided spans for the discovered caller/guard closure cannot fit source/reference budget; no tied/required module was confidence-picked. Omitted related paths: " + omissions.joined(separator: ", ") + inventoryNote, omittedRelatedPaths: omissions))
        }
        if !fits(output + ui) {
            // Optional client evidence cannot poison otherwise valid host
            // context. Its route is explicitly unverified, never certified by
            // the surviving HTML label or missing helper bodies.
            unverifiedClientOwners += clientNodes.count
            for id in clientNodes { omittedClientCalls.formUnion(index.declarationInventory[id].calls) }
            navigationSkipped += ui.count; ui = []
        }
        // Stable original source order gives stable passage IDs across related
        // questions. Per-question UI/document evidence always follows it.
        output.sort { a, b in
            let primaryPath = index.source.files[primary].path
            if (a.citation.path == primaryPath) != (b.citation.path == primaryPath) { return a.citation.path == primaryPath }
            let order = ["module": 0, "related_declarations": 1, "loader": 2]
            if a.contextRole != b.contextRole { return (order[a.contextRole ?? ""] ?? 3) < (order[b.contextRole ?? ""] ?? 3) }
            return a.citation.path == b.citation.path ? a.citation.startLine < b.citation.startLine : a.citation.path < b.citation.path
        }
        output += ui
        let clientNote = " Ranked client owners: \(clientNodes.count); navigation-only seeds skipped: \(navigationSkipped); unverified client routes: \(unverifiedClientOwners). UI direct-helper depth1/node32/64KiB bounds; deeper omitted callable names: " + omittedClientCalls.sorted().joined(separator: ", ") + ". If an answer depends on missing client behavior, give a concrete needs-check instead. HTML alone is not client implementation proof."
        return scoped(.init(passages: output, note: "Selected whole lexical primary, exact complete original spans for ranked-owner-linked discovered declarations/helpers or whole related files, and declared-loader spans; broad context, not pinpoint spans or an exhaustive graph. Literal references do not prove paths, conditional execution, active runtime or deployment. Separate unresolved loader routines: \(scope.unresolvedLoaders.count); dispatch, path and override behavior remain unverified." + clientNote + inventoryNote, clientOwnerCount: clientNodes.count, clientNavigationSkippedCount: navigationSkipped, unverifiedClientOwnerCount: unverifiedClientOwners, omittedClientCallNames: omittedClientCalls.sorted()))
    }

    private struct Token { let value: String; let literal: Bool }
    private static func tokenize(_ text: String) -> [Token]? {
        guard text.utf8.count <= 128 * 1024 else { return nil }
        let b = Array(text.utf8); var out: [Token] = [], i = 0
        func word(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) || (48...57).contains(c) || c == 95 || c == 36 }
        while i < b.count && out.count < 32_768 {
            let c = b[i], n = i + 1 < b.count ? b[i + 1] : 0
            if c <= 32 { i += 1; continue }
            if c == 47 && n == 47 { while i < b.count && b[i] != 10 { i += 1 }; continue }
            if c == 47 && n == 42 {
                i += 2; var closed = false
                while i + 1 < b.count { if b[i] == 42 && b[i + 1] == 47 { i += 2; closed = true; break }; i += 1 }
                guard closed else { return nil }; continue
            }
            if c == 34 || c == 39 || c == 96 {
                let quote = c; i += 1; let start = i; var escaped = false
                while i < b.count && b[i] != quote { if b[i] == 92 { escaped = true; i += 1 }; i += 1 }
                guard i < b.count else { return nil }
                out.append(.init(value: escaped || quote == 96 ? "" : String(decoding: b[start..<i], as: UTF8.self), literal: true)); i += 1; continue
            }
            if c == 47 && ["", "=", "(", "[", ",", ":", "!", "&", "|", "?", "{", ";", "return", "throw", "case"].contains(out.last?.value ?? "") {
                i += 1; var cls = false, closed = false
                while i < b.count { let v = b[i]; i += 1; if v == 92 { i += min(1, b.count - i); continue }; if v == 91 { cls = true }; if v == 93 { cls = false }; if v == 47 && !cls { closed = true; break } }
                guard closed else { return nil }; out.append(.init(value: "", literal: true)); continue
            }
            // Ambiguous division/regex syntax is outside the loader grammar.
            if c == 47 { return nil }
            if word(c) { let start = i; while i < b.count && word(b[i]) { i += 1 }; out.append(.init(value: String(decoding: b[start..<i], as: UTF8.self), literal: false)) }
            else { out.append(.init(value: String(UnicodeScalar(c)), literal: false)); i += 1 }
        }
        return i == b.count ? out : nil
    }

    private static func loadedNames(_ text: String) -> (names: [String], complete: Bool, recognized: Bool) {
        guard let t = tokenize(text) else { return ([], false, true) }; let v = t.map(\.value)
        guard t.filter({ !$0.literal && $0.value == "function" }).count <= 1 else { return ([], false, true) }
        func at(_ i: Int, _ s: String) -> Bool { v.indices.contains(i) && !t[i].literal && v[i] == s }
        func close(_ start: Int, _ open: String, _ shut: String) -> Int? { var depth = 0; for i in start..<v.count { if at(i, open) { depth += 1 }; if at(i, shut) { depth -= 1; if depth == 0 { return i } } }; return nil }
        func mutation(_ i: Int) -> Bool {
            if at(i, "=") { return !at(i + 1, "=") && !at(i + 1, ">") }
            guard v.indices.contains(i), !t[i].literal else { return false }
            if ["+", "-", "*", "/", "%", "&", "|", "^"].contains(v[i]) && at(i + 1, "=") { return true }
            return (at(i, "+") && at(i + 1, "+")) || (at(i, "-") && at(i + 1, "-"))
        }
        var assignments: [String: Int] = [:]
        for i in v.indices where !t[i].literal && !at(i - 1, ".") && at(i + 1, "=") && !at(i + 2, "=") { assignments[v[i], default: 0] += 1 }
        var arrays: [String: (Int, [String], Bool)] = [:], bindings: [String: (Int, String)] = [:], names: [String] = []
        var complete = true, evaluations = 0
        for i in v.indices where ["var", "let", "const"].contains(v[i]) && !t[i].literal {
            guard v.indices.contains(i + 3), !t[i + 1].literal, at(i + 2, "=") else { continue }; let name = v[i + 1]
            if at(i + 3, "["), let end = close(i + 3, "[", "]") {
                var values: [String] = [], valid = true, expect = true
                for k in (i + 4)..<end { if expect && t[k].literal && !v[k].isEmpty { values.append(v[k]); expect = false } else if !expect && at(k, ",") { expect = true } else { valid = false } }
                valid = valid && at(end + 1, ";") && !values.isEmpty && Set(values).count == values.count && assignments[name] == 1
                for k in v.indices where !t[k].literal && v[k] == name {
                    if at(k - 1, "delete") || (at(k - 1, "+") && at(k - 2, "+")) || (at(k - 1, "-") && at(k - 2, "-")) { valid = false }
                    if at(k + 1, ".") && !at(k + 2, "length") { valid = false }
                    if at(k + 1, ".") && at(k + 2, "length") && mutation(k + 3) { valid = false }
                    if !at(k + 1, "=") && mutation(k + 1) { valid = false }
                    if at(k + 1, "["), let end = close(k + 1, "[", "]"), mutation(end + 1) { valid = false }
                }
                if arrays[name] != nil { valid = false; complete = false }; arrays[name] = (i, values, valid)
            }
            if at(i + 3, "new"), at(i + 4, "File"), at(i + 5, "("), let end = close(i + 5, "(", ")") {
                let candidates = ((i + 6)..<end).filter { !t[$0].literal && at($0 + 1, "[") && v.indices.contains($0 + 3) && !t[$0 + 2].literal && at($0 + 3, "]") }.map { v[$0] }
                let position = ((i + 6)..<end).first { !t[$0].literal && at($0 + 1, "[") }
                let literalLeaf = position.map { $0 + 4 == end && ($0 == i + 6 || (at($0 - 1, "+") && t[$0 - 2].literal && v[$0 - 2].hasSuffix("/"))) } ?? false
                if candidates.count == 1 && literalLeaf && at(end + 1, ";") && assignments[name] == 1 && bindings[name] == nil { bindings[name] = (i, candidates[0]) } else { complete = false }
            }
        }
        for i in v.indices where at(i, "$") && at(i + 1, ".") && at(i + 2, "evalFile") {
            evaluations += 1
            guard at(i + 3, "("), v.indices.contains(i + 5), !t[i + 4].literal, at(i + 5, ")"), let binding = bindings[v[i + 4]], binding.0 < i, let array = arrays[binding.1], array.0 < binding.0, array.2 else { complete = false; continue }
            for name in array.1 { if name.contains("/") || name.contains("\\") || name.contains("..") || name.contains(where: { $0.isNewline }) || names.contains(name) { complete = false } else { names.append(name) } }
        }
        return (names, complete && evaluations > 0, !arrays.isEmpty || !bindings.isEmpty)
    }
}
