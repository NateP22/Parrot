import Foundation
import Darwin

enum ReviewedSelectorInputChecks {
    static func run(_ check: (String, Bool) -> Void) {
        do {
            let catalogData = ReviewedAnswerTests.fixtureData
            let signed = try ReviewedAnswerCatalog.decode(catalogData)
            let source = signed.sources[0], answer = signed.answers[0]
            func writeJSON(_ object: Any, _ url: URL) throws {
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
            }
            func fixture(_ body: (URL, URL, inout [String: Any]) throws -> Void) throws {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("selector-input-"+UUID().uuidString)
                let group = root.appendingPathComponent("frozen")
                try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                try catalogData.write(to: group.appendingPathComponent("catalog.json"))
                try Data(source.text.utf8).write(to: group.appendingPathComponent("source.md"))
                let cases: [[String: Any]] = [["id":"example-1", "question":"How do I export a saved draft?", "previous":"",
                    "expected_unit":"DO_NOT_SEND_ORACLE", "review_required":true]]
                try writeJSON(cases, group.appendingPathComponent("cases.json"))
                let casesData = try Data(contentsOf: group.appendingPathComponent("cases.json"))
                var manifest: [String: Any] = [
                    "schema":1, "buildCommit":String(repeating:"1",count:40),
                    "catalog":["path":"catalog.json","sha256":ReviewedAnswerCatalog.sha256(catalogData)],
                    "cases":["path":"cases.json","sha256":ReviewedAnswerCatalog.sha256(casesData)],
                    "sources":[["sourceID":source.id,"path":"source.md","sha256":source.sha256]],
                    "units":[["id":answer.id,"digest":answer.contentDigest]],
                    "modes":["isolated","rolling"], "resultPath":"observations.jsonl"
                ]
                let url = group.appendingPathComponent("manifest.json")
                try writeJSON(manifest, url)
                try body(root, url, &manifest)
            }
            func reject(_ name: String, code: ReviewedSelectorInput.Failure? = nil,
                        _ mutation: (URL, inout [String: Any]) throws -> Void) {
                do {
                    try fixture { root, url, manifest in
                        try mutation(url.deletingLastPathComponent(), &manifest)
                        try writeJSON(manifest, url)
                        do {
                            _ = try ReviewedSelectorInput.prepare(manifestURL:url, allowedRoot:root)
                            check("selector input rejects "+name, false)
                        } catch {
                            check("selector input rejects "+name, code == nil || error as? ReviewedSelectorInput.Failure == code)
                        }
                    }
                } catch { check("selector input fixture failed for "+name, false) }
            }
            do { try fixture { root, url, _ in
                let prepared = try ReviewedSelectorInput.prepare(manifestURL:url, allowedRoot:root)
                check("selector input normal signed bytes admit the complete unit",
                      prepared.snapshot.answers.count == 1 && prepared.snapshot.answers.first?.id == answer.id && prepared.snapshot.admissionIssues.isEmpty)
                check("selector input retains exact case wording and modes",
                      prepared.cases.count == 1 && prepared.cases[0].id == "example-1" &&
                      prepared.cases[0].question == "How do I export a saved draft?" && prepared.modes == ["isolated","rolling"])
                let projected = String(decoding:try JSONEncoder().encode(prepared.cases), as:UTF8.self)
                check("selector input excludes oracle and unresolved annotations from execution",
                      !projected.contains("DO_NOT_SEND_ORACLE") && !projected.contains("expected_unit") && !projected.contains("review_required"))
                check("selector input hashes the actual captured manifest", prepared.manifestSHA256 == ReviewedAnswerCatalog.sha256(try Data(contentsOf:url)))
            } } catch { check("selector input accepts a complete valid signed fixture: "+String(describing:error), false) }
            for parentAlias in [false, true] {
                try fixture { root, url, _ in
                    let alias = root.deletingLastPathComponent().appendingPathComponent("selector-alias-"+UUID().uuidString)
                    try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:parentAlias ? root.deletingLastPathComponent() : root)
                    defer { try? FileManager.default.removeItem(at:alias) }
                    let allowed = parentAlias ? alias.appendingPathComponent(root.lastPathComponent) : alias
                    let manifest = allowed.appendingPathComponent("frozen/manifest.json")
                    do {
                        _ = try ReviewedSelectorInput.prepare(manifestURL:manifest,allowedRoot:allowed)
                        check("selector input rejects owned "+(parentAlias ? "parent" : "root")+" symlink",false)
                    } catch {
                        check("selector input rejects owned "+(parentAlias ? "parent" : "root")+" symlink",error as? ReviewedSelectorInput.Failure == .unsafePath)
                    }
                }
            }
            reject("same-length source mutation") { group, _ in
                var data = Data(source.text.utf8); data[0] ^= 1
                try data.write(to:group.appendingPathComponent("source.md"))
            }
            reject("missing source inventory") { _, m in m["sources"] = [] }
            reject("duplicate source inventory") { _, m in m["sources"] = [m["sources"] as! [[String:Any]],m["sources"] as! [[String:Any]]].flatMap{$0} }
            reject("unknown source inventory") { _, m in m["sources"] = [["sourceID":"s-unknown","path":"source.md","sha256":source.sha256]] }
            reject("wrong complete unit digest") { _, m in m["units"] = [["id":answer.id,"digest":String(repeating:"0",count:64)]] }
            reject("missing unit inventory") { _, m in m["units"] = [] }
            reject("catalog hash mismatch") { _, m in m["catalog"] = ["path":"catalog.json","sha256":String(repeating:"0",count:64)] }
            reject("untrusted changed catalog") { group, m in
                var data = catalogData; data[data.count-2] ^= 1
                try data.write(to:group.appendingPathComponent("catalog.json"))
                m["catalog"] = ["path":"catalog.json","sha256":ReviewedAnswerCatalog.sha256(data)]
            }
            reject("source path escape",code:.unsafePath) { _, m in
                m["sources"] = [["sourceID":source.id,"path":"../source.md","sha256":source.sha256]]
            }
            reject("source URL",code:.unsafePath) { _, m in
                m["sources"] = [["sourceID":source.id,"path":"https://example.invalid/source","sha256":source.sha256]]
            }
            reject("symlink source",code:.unsafePath) { group, _ in
                let path=group.appendingPathComponent("source.md")
                try FileManager.default.removeItem(at:path)
                try FileManager.default.createSymbolicLink(at:path,withDestinationURL:group.appendingPathComponent("catalog.json"))
            }
            reject("directory source") { group, _ in
                let path=group.appendingPathComponent("source.md")
                try FileManager.default.removeItem(at:path)
                try FileManager.default.createDirectory(at:path,withIntermediateDirectories:false)
            }
            reject("FIFO source") { group, _ in
                let path=group.appendingPathComponent("source.md")
                try FileManager.default.removeItem(at:path)
                guard mkfifo(path.path,0o600)==0 else { throw ReviewedSelectorInput.Failure.invalidInput }
            }
            reject("oversized manifest before decoding",code:.tooLarge) { _, m in m["padding"]=String(repeating:" ",count:262_145) }
            reject("oversized catalog before hashing",code:.tooLarge) { group, _ in
                let h=try FileHandle(forWritingTo:group.appendingPathComponent("catalog.json")); defer{try? h.close()}
                try h.truncate(atOffset:1_048_577)
            }
            reject("oversized cases before hashing",code:.tooLarge) { group, _ in
                let h=try FileHandle(forWritingTo:group.appendingPathComponent("cases.json")); defer{try? h.close()}
                try h.truncate(atOffset:262_145)
            }
            reject("oversized source before hashing",code:.tooLarge) { group, _ in
                let h=try FileHandle(forWritingTo:group.appendingPathComponent("source.md")); defer{try? h.close()}
                try h.truncate(atOffset:524_289)
            }
            func replaceCases(_ cases:[[String:Any]], _ group:URL, _ m:inout[String:Any]) throws {
                let url=group.appendingPathComponent("cases.json");try writeJSON(cases,url)
                m["cases"]=["path":"cases.json","sha256":ReviewedAnswerCatalog.sha256(try Data(contentsOf:url))]
            }
            reject("empty cases") { g,m in try replaceCases([],g,&m) }
            reject("duplicate case identities") { g,m in try replaceCases([["id":"same","question":"How do I export?","previous":""],["id":"same","question":"How do I save?","previous":""]],g,&m) }
            reject("129 cases") { g,m in try replaceCases((0..<129).map{["id":"case-"+String($0),"question":"How do I export?","previous":""]},g,&m) }
            reject("blank question") { g,m in try replaceCases([["id":"blank","question":"  ","previous":""]],g,&m) }
            reject("overlong question") { g,m in try replaceCases([["id":"long","question":String(repeating:"q",count:4_001),"previous":""]],g,&m) }
            reject("unknown execution mode") { _,m in m["modes"]=["other"] }
            reject("duplicate execution mode") { _,m in m["modes"]=["isolated","isolated"] }
            reject("existing output",code:.outputExists) { g,_ in try Data("existing".utf8).write(to:g.appendingPathComponent("observations.jsonl")) }
            reject("output input collision") { _,m in m["resultPath"]="source.md" }
            reject("output escape",code:.unsafePath) { _,m in m["resultPath"]="../outside.jsonl" }
            reject("unexpected frozen file") { g,_ in try Data("extra".utf8).write(to:g.appendingPathComponent("unlisted.txt")) }
        } catch { check("selector input valid fixture preparation", false) }
    }
}
