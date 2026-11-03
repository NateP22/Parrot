import Foundation

@main
enum RepositoryKnowledgeComponentTest {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: Bool) {
            precondition(value, name)
            count += 1
            print("PASS \(name)")
        }
        func file(_ path: String, _ text: String) -> RepositoryKnowledge.File {
            let bytes = Data(text.utf8)
            return .init(path: path, blob: RepositoryKnowledge.gitBlob(bytes),
                         sha256: RepositoryKnowledge.digest(bytes), text: text)
        }
        func packet(_ files: [RepositoryKnowledge.File], commit: String = String(repeating: "a", count: 40)) throws -> Data {
            try JSONEncoder().encode(RepositoryKnowledge(schemaVersion: 1, repository: "fictional/atlas",
                requestedRef: "main", commit: commit, files: files))
        }
        func refuses(_ bytes: Data) -> Bool { (try? RepositoryKnowledge.decode(bytes)) == nil }
        check("Git blob known independent vector", RepositoryKnowledge.gitBlob(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
        check("SHA256 known independent vector", RepositoryKnowledge.digest(Data("hello\n".utf8)) == "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
        let input = [file("client/settings.json", "{\"allowLinks\":false}\n"),
                     file("host/settings.json", "{\"allowLinks\":true}\n"),
                     file("host/Line space.jsx", "if (enabled) {\r\n  go();\r\n}\r\n")]
        let data = try packet(input)
        let source = try RepositoryKnowledge.decode(data)
        check("JSON code and duplicate basenames are distinct", source.files.count == 3)
        let passages = source.passages(linesPerChunk: 2, overlap: 1)
        check("short config statements retained", passages.contains { $0.text == "{\"allowLinks\":false}\n" })
        check("terminal newline does not invent GitHub line 2", passages.first { $0.citation.path == "client/settings.json" }?.citation.endLine == 1)
        check("CRLF ends on real line 3", passages.filter { $0.citation.path == "host/Line space.jsx" }.map { $0.citation.endLine }.max() == 3)
        let oneCRLF = try RepositoryKnowledge.decode(packet([file("host/one.js", "x\r\n")])).passages()
        check("one CRLF line cites L1-L1", oneCRLF.count == 1 && oneCRLF[0].citation.startLine == 1 && oneCRLF[0].citation.endLine == 1 && oneCRLF[0].text == "x\r\n")
        for text in ["a\nb", "a\n\n"] {
            let edge = try RepositoryKnowledge.decode(packet([file("host/edge.js", text)])).passages()
            check("final newline edge preserves exact two real lines", edge.count == 1 && edge[0].citation.endLine == 2 && edge[0].text == text)
        }
        for passage in passages {
            let original = input.first { $0.path == passage.citation.path }!.text.components(separatedBy: "\n")
            check("exact source line reconstruction \(passage.citation.label)",
                  original[(passage.citation.startLine - 1)..<passage.citation.endLine].joined(separator: "\n")
                    + (passage.citation.endLine < original.count ? "\n" : "") == passage.text)
            check("citation revision pinned", passage.citation.revision == source.revision)
        }
        let citation = passages.first { $0.citation.path.contains(" ") }!.citation
        check("app URL escapes spaces", citation.url.absoluteString.contains("Line%20space.jsx#L"))
        check("URL pins full commit", citation.url.absoluteString.contains(source.commit))
        check("no model URL accepted", citation.url.host == "github.com")
        let reordered = try RepositoryKnowledge.decode(packet(input.reversed()))
        check("revision independent of file order", reordered.revision == source.revision)
        let next = try RepositoryKnowledge.decode(packet(input, commit: String(repeating: "b", count: 40)))
        check("new commit has new revision", next.revision != source.revision)
        let changed = try RepositoryKnowledge.decode(packet([file("client/settings.json", "{\"allowLinks\":true}\n")]))
        check("inventory/bytes change revision", changed.revision != source.revision)
        let bad = RepositoryKnowledge.File(path: "client/settings.json", blob: input[0].blob,
            sha256: input[0].sha256, text: "changed")
        check("tampered bytes refused", refuses(try packet([bad])))
        check("duplicate path refused", refuses(try packet([input[0], input[0]])))
        check("case collision refused", refuses(try packet([input[0], file("Client/settings.json", "x") ])))
        check("symbolic commit refused", refuses(try packet(input, commit: "main")))
        check("empty inventory refused", refuses(try packet([])))
        for path in ["../x.js", "/x.js", "x/../y.js", "x\\y.js", "x//y.js", "x/./y.js", ".env.json",
                     "secrets/key.json", "api-keys.json", "token.json", "keychain.json", "node_modules/x.js", "vendor/x.js", "docs/example.js", "tests/x.js", "x.min.js", "x.test.js", "a\nb.js"] {
            check("unsafe/nonruntime path refused \(path.debugDescription)", !RepositoryKnowledge.permits(path: path))
        }
        check("credential content refused", refuses(try packet([file("client/a.js", "const key = \"sk-ant-" + String(repeating: "X", count: 30) + "\";")])))
        check("binary NUL refused", refuses(try packet([file("client/a.js", "x\0y")])))
        for marker in ["sk-" + String(repeating: "Q", count: 30), "xoxb-" + String(repeating: "Q", count: 30),
                       "AIza" + String(repeating: "Q", count: 32), "AKIA" + String(repeating: "Q", count: 16),
                       "const password = \"fictionalLongValue123\";"] {
            check("additional credential family refused", refuses(try packet([file("client/a.js", marker)])))
        }
        check("camelCase split for spoken words", RepositoryKnowledge.tokens("allowLinks pageJumps").contains("jumps"))
        if CommandLine.arguments.count == 2 {
            let package = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let actual = try RepositoryKnowledge.decode(package)
            check("actual exported snapshot decodes", !actual.files.isEmpty)
            check("actual file paths unique", Set(actual.files.map(\.path)).count == actual.files.count)
            print("ACTUAL_SOURCE commit=\(actual.commit) files=\(actual.files.count) revision=\(actual.revision)")
        }
        print("\(count) component checks passed; native answers and timing NOT tested")
    }
}
