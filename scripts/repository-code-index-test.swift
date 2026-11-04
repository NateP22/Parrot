import Foundation

@main
enum RepositoryCodeIndexTest {
    static func main() throws {
        var failures = 0, checks = 0
        func check(_ name: String, _ value: Bool) {
            checks += 1
            if !value { failures += 1 }
            print("\(value ? "PASS" : "FAIL") \(name)")
        }
        func file(_ path: String, _ text: String) -> RepositoryKnowledge.File {
            let bytes = Data(text.utf8)
            return .init(path: path, blob: RepositoryKnowledge.gitBlob(bytes),
                sha256: RepositoryKnowledge.digest(bytes), text: text)
        }
        let files = [file("desktop/render.js", "function renderLabel(value) {\r\n  return resolveLabel(value);\r\n}\r\n"),
            file("desktop/resolve.js", "function resolveLabel(value) {\n  if (!value.ready) { return null; }\n  return value.label;\n}\n"),
            file("server/render.js", "function renderLabel(value) { return value.label; }\n")]
        let base = RepositoryKnowledge(schemaVersion: 1, repository: "fictional/atlas",
            requestedRef: "main", commit: String(repeating: "a", count: 40), files: files)
        func packet(_ scopes: [[String: Any]]) throws -> Data {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
            json["runtimeScopes"] = scopes
            return try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        }
        let desktop: [String: Any] = ["id": "desktop", "name": "Desktop", "roots": ["desktop/"],
            "entryPoints": ["desktop/render.js"], "dependencyRoots": []]
        let server: [String: Any] = ["id": "server", "name": "Server", "roots": ["server/"],
            "entryPoints": ["server/render.js"], "dependencyRoots": []]
        let source = try RepositoryKnowledge.decode(packet([desktop, server]))
        var renamed = desktop; renamed["name"] = "Desktop updated"
        let changed = try RepositoryKnowledge.decode(packet([renamed, server]))
        check("runtime policy participates in evidence revision", source.revision != changed.revision)
        var unknownEntry = desktop; unknownEntry["entryPoints"] = ["desktop/missing.js"]
        check("scope entry point must exist in original inventory", (try? RepositoryKnowledge.decode(packet([unknownEntry, server]))) == nil)
        var wrongRuntime = desktop; wrongRuntime["entryPoints"] = ["server/render.js"]
        check("scope entry point must belong to its primary roots", (try? RepositoryKnowledge.decode(packet([wrongRuntime, server]))) == nil)
        var traversal = desktop; traversal["roots"] = ["desktop/../server/"]
        check("scope roots cannot escape their declared subtree", (try? RepositoryKnowledge.decode(packet([traversal, server]))) == nil)
        check("duplicate scope identities refused", (try? RepositoryKnowledge.decode(packet([desktop, desktop]))) == nil)
        var overlapping = server; overlapping["roots"] = ["server/", "desktop/"]
        check("primary runtime ownership cannot overlap", (try? RepositoryKnowledge.decode(packet([desktop, overlapping]))) == nil)
        var foreignTree = desktop; foreignTree["dependencyRoots"] = ["server/"]
        check("cross-runtime dependency cannot sweep another runtime tree", (try? RepositoryKnowledge.decode(packet([foreignTree, server]))) == nil)
        var explicitDependency = desktop; explicitDependency["dependencyRoots"] = ["server/render.js"]
        check("explicit original dependency remains available", (try? RepositoryKnowledge.decode(packet([explicitDependency, server]))) != nil)
        let passages = source.passages(linesPerChunk: 2, overlap: 1)
        let index = RepositoryCodeIndex(source: source, passages: passages)
        check("no default runtime guessed", index.primaryPassageIndices(scopeID: nil).isEmpty)
        check("unknown runtime fails closed", index.primaryPassageIndices(scopeID: "missing").isEmpty)
        check("desktop ranking excludes server implementation", index.primaryPassageIndices(scopeID: "desktop").allSatisfy { passages[$0].citation.path.hasPrefix("desktop/") })
        let seed = passages.firstIndex { $0.citation.path == "desktop/render.js" }!
        let expanded = index.expanded(seedIndices: [seed], scopeID: "desktop")
        check("related definition retains early-return guard outside seed", expanded.contains { $0.citation.path == "desktop/resolve.js" && $0.text.contains("!value.ready") })
        check("selected declaration is not cut at chunk boundary", expanded.contains { $0.citation.path == "desktop/render.js" && $0.text == files[0].text })
        check("other runtime cannot enter structural evidence", expanded.allSatisfy { $0.citation.path.hasPrefix("desktop/") })
        check("bounded context fails closed rather than cutting function", index.expanded(seedIndices: [seed], scopeID: "desktop", maximumCharacters: 5).isEmpty)
        check("required alternatives cannot be silently trimmed to one slot", index.expanded(seedIndices: [seed], scopeID: "desktop", limit: 1).isEmpty)
        for span in expanded {
            let original = files.first { $0.path == span.citation.path }!
            let rawLines = original.text.components(separatedBy: "\n")
            let exact = rawLines[(span.citation.startLine - 1)..<span.citation.endLine].joined(separator: "\n")
                + (span.citation.endLine < rawLines.count ? "\n" : "")
            check("expanded citation preserves original CRLF/lines", span.text == exact && span.citation.revision == source.revision && span.citation.sha256 == original.sha256)
        }
        var reordered = desktop; reordered["roots"] = ["desktop/resolve.js", "desktop/render.js"]
        let reorderedSource = try RepositoryKnowledge.decode(packet([reordered, server]))
        var reorderedAgain = reordered; reorderedAgain["roots"] = ["desktop/render.js", "desktop/resolve.js"]
        check("scope order and root order do not change revision", reorderedSource.revision == (try RepositoryKnowledge.decode(packet([server, reorderedAgain]))).revision)
        func single(_ text: String) throws -> RepositoryCodeIndex {
            let code = RepositoryKnowledge(schemaVersion: 1, repository: "fictional/atlas", requestedRef: "main",
                commit: String(repeating: "b", count: 40), files: [file("desktop/logic.js", text)],
                runtimeScopes: [.init(id: "desktop", name: "Desktop", roots: ["desktop/"], entryPoints: ["desktop/logic.js"], dependencyRoots: [])])
            let verified = try RepositoryKnowledge.decode(JSONEncoder().encode(code))
            return RepositoryCodeIndex(source: verified, passages: verified.passages(linesPerChunk: 2, overlap: 1))
        }
        for literal in ["const a = '}';", "const a = /[{}]/;", "/* } function falseHit() { */", "const a = `opaque ${value}`;", "const a = 7 / 2;"] {
            let text = "function renderLabel(value) {\n  \(literal)\n  if (!value.ready) return null;\n  return value.label;\n}\n"
            let hints = try single(text)
            let spans = hints.expanded(seedIndices: [0], scopeID: "desktop")
            check("literal/comment braces do not cut a real guard", spans.first?.text == text && hints.declarations.count == 1)
        }
        let regexReturn = try single("function sample(value) {\n  if (value.ready) return /}/.test(value.label);\n  return false;\n}\n")
        check("regex after return cannot terminate a function", regexReturn.expanded(seedIndices: [0], scopeID: "desktop").first?.citation.endLine == 4)
        let overloaded = try single("function renderLabel(value) { return resolveLabel(value); }\nfunction resolveLabel(value) { return value.ready; }\nfunction resolveLabel(value, mode) { return mode && value.ready; }\n")
        check("duplicate definition spellings retained as alternatives", overloaded.expanded(seedIndices: [0], scopeID: "desktop").count == 3)
        let many = try single((0..<300).map { "function fixture\($0)() { return \($0); }" }.joined(separator: "\n"))
        check("declaration preparation has a per-file bound", many.declarations.count == 256)
        let markup = try single("function Component(value) {\n  return <div>{value.label}</div>;\n}\n")
        check("mixed JSX is not claimed as parsed declarations", markup.declarations.isEmpty)
        let namespaced = try single("function renderLabel(value) { return Atlas.resolve(value); }\nAtlas.resolve = function(value) { if (!value.ready) return null; return value.label; };\nOther.resolve = function(value) { return 'wrong runtime'; };\n")
        let namespaceSpans = namespaced.expanded(seedIndices: [0], scopeID: "desktop")
        check("qualified calls do not collapse unrelated object methods", namespaceSpans.contains { $0.text.contains("Atlas.resolve =") } && !namespaceSpans.contains { $0.text.contains("Other.resolve =") })
        for annotation in ["Promise<{review: string; section: string}>", "{review: string; section: string}"] {
            let text = "function copyReview(input): \(annotation) {\n if (!input.ready) throw Error('not ready');\n if (input.privateMode) return null;\n return input;\n}\n"
            let typed = try single(text)
            check("inline object return type cannot replace executable body", typed.declarationInventory.count == 1 && typed.declarationInventory[0].endLine == 5 && typed.passage(file: 0, start: typed.declarationInventory[0].startLine, end: typed.declarationInventory[0].endLine).text == text)
        }
        let ambiguousType = try single("function uncertain(input): Input extends Other ? {ok: boolean} : {no: boolean} {\n if (!input.ready) return false;\n return true;\n}\n")
        check("unsupported conditional return annotation never claims header-only body", ambiguousType.declarationInventory.isEmpty && ambiguousType.fileCoverage[0]?.reasons.contains("unsupported-function-header") == true)
        let definitionScope = try single("var Atlas={};\nAtlas.draw=function(Atlas){return Atlas.local();};\nfunction other(Atlas){return Atlas.other();}\n")
        check("definition namespace precedes own parameter scope while call is shadowed", definitionScope.declarationInventory.first?.definitionBindings.contains("Atlas") == false && definitionScope.declarationInventory.first?.localBindings.contains("Atlas") == true)
        for (text, reason) in [("const guard = (v) => { if (v.blocked) return false; return v.ready; };\n", "unsupported-arrow-function"), ("var Guard={ allow(v){if(v.blocked)return false;return v.ready;} };\n", "unsupported-concise-method-syntax"), ("class Guard { allow(v){return !v.blocked;} }\n", "unsupported-class-method-syntax"), ("const Guard=class { static allow(v){return !v.blocked;} };\n", "unsupported-class-method-syntax")] {
            let unsupported = try single(text)
            check("unsupported executable form marks bounded inventory honestly", unsupported.fileCoverage[0]?.declarationInventoryComplete == false && unsupported.fileCoverage[0]?.reasons.contains(reason) == true)
        }
        let syntaxLiteral = try single("function literal(){ const text='=> class Fake { concise(){} }'; /* () => {} */ return true; }\n")
        check("comments/strings do not create unsupported syntax coverage flags", syntaxLiteral.fileCoverage[0]?.declarationInventoryComplete == true)
        print("\(checks) checks; \(failures) failures; fictional source only; no native/model acceptance")
        if failures > 0 { exit(1) }
    }
}
