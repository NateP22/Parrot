import Foundation

@main enum RepositoryModuleContextTest {
    static func main() throws {
        var checks = 0, failures = 0
        func check(_ name: String, _ ok: Bool) { checks += 1; print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
        func file(_ path: String, _ text: String) -> RepositoryKnowledge.File {
            .init(path: path, blob: RepositoryKnowledge.gitBlob(Data(text.utf8)), sha256: RepositoryKnowledge.digest(Data(text.utf8)), text: text)
        }
        let module = "var Atlas = {};\nAtlas.draw = function(value) { return Guard.allow(value); };\n" + String(repeating: "// unrelated original context\n", count: 180) + "Atlas.exception = function(value) { if (value.privateMode) return false; return true; };\n"
        let helper = "var Guard = {};\nGuard.allow = function(value) {\n if (!value.ready) return false;\n return value.allowed;\n};\n"
        let loader = "function boot(root) {\n var modules = ['alpha.js', 'helper.js', 'other.js'];\n for (var i=0; i<modules.length; i++) {\n  var item = new File(root + '/' + modules[i]);\n  if (item.exists) { $.evalFile(item); }\n }\n}\n"
        func make(_ load: String = "", extra: [RepositoryKnowledge.File] = [], huge: Bool = false,
                  limits: RepositoryCodeIndex.Limits = .init(), html: String = "<label>Visibility</label>\n", helperText: String? = nil) throws -> (RepositoryKnowledge, RepositoryCodeIndex, RepositoryModuleContext) {
            let files = [file("desktop/loader.js", load.isEmpty ? loader : load), file("desktop/alpha.js", huge ? module + String(repeating: "// large context\n", count: 40_000) : module), file("desktop/helper.js", helperText ?? helper),
                file("desktop/other.js", "Other.draw = function(value) { return value; };\n"),
                file("desktop/main.jsx", "Atlas.draw = function(value) { return 'dead'; };\n"),
                file("client/ui.html", html),
                file("server/api.js", "function api(value) { if (!value.ready) return false; return value; }\n")] + extra
            let value = RepositoryKnowledge(schemaVersion: 1, repository: "fictional/atlas", requestedRef: "main", commit: String(repeating: "a", count: 40), files: files,
                runtimeScopes: [.init(id: "desktop", name: "Desktop", roots: ["desktop/", "client/"], entryPoints: ["desktop/loader.js", "client/ui.html"], dependencyRoots: []),
                    .init(id: "server", name: "Server", roots: ["server/"], entryPoints: ["server/api.js"], dependencyRoots: [])])
            let source = try RepositoryKnowledge.decode(JSONEncoder().encode(value))
            let index = RepositoryCodeIndex(source: source, passages: source.passages(linesPerChunk: 4, overlap: 1), limits: limits)
            return (source, index, RepositoryModuleContext(index: index))
        }
        let (source, index, context) = try make()
        let seed = index.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let ui = index.passages.firstIndex { $0.citation.path == "client/ui.html" }!
        let selected = context.select(seeds: [seed, ui], scopeID: "desktop")
        check("whole module retains far-away exception", selected.passages.contains { $0.text == module && $0.contextRole == "module" })
        check("qualified helper keeps full early-return condition", selected.passages.contains { $0.text == helper && $0.contextRole == "module" })
        check("complete conditional loader retained with uncertainty", selected.passages.contains { $0.text == loader && $0.contextRole == "loader" } && selected.note.contains("conditional execution"))
        check("dead main and unrelated namespace excluded", selected.passages.allSatisfy { !["desktop/main.jsx", "desktop/other.js"].contains($0.citation.path) })
        check("UI remains varying suffix evidence", selected.passages.last?.contextRole == "ui")
        check("six-reference and byte budgets", selected.passages.count <= 6 && selected.passages.reduce(0) { $0 + $1.text.utf8.count } <= RepositoryModuleContext.maximumBytes)
        for span in selected.passages {
            let original = source.files.first { $0.path == span.citation.path }!
            let lines = original.text.components(separatedBy: "\n")
            let exact = lines[(span.citation.startLine - 1)..<span.citation.endLine].joined(separator: "\n") + (span.citation.endLine < lines.count ? "\n" : "")
            check("original citation bytes/path/blob/hash", span.text == exact && span.citation.blob == original.blob && span.citation.sha256 == original.sha256 && span.citation.revision == source.revision)
        }
        let again = context.select(seeds: [seed], scopeID: "desktop")
        check("same owner with changed UI preserves stable prefix order", selected.passages.filter { $0.contextRole != "ui" }.map(\.citation) == again.passages.filter { $0.contextRole != "ui" }.map(\.citation))
        for (name, changed) in [
            ("missing file", loader.replacingOccurrences(of: "helper.js", with: "missing.js")),
            ("dynamic array", loader.replacingOccurrences(of: "'helper.js'", with: "chooseModule()")),
            ("dynamic array postfix", loader.replacingOccurrences(of: "'other.js'];", with: "'other.js'].concat(dynamicNames);")),
            ("duplicate load", loader.replacingOccurrences(of: "'helper.js'", with: "'alpha.js'")),
            ("changed leaf", loader.replacingOccurrences(of: "modules[i])", with: "modules[i] + '.bak')")),
            ("mutated array", loader.replacingOccurrences(of: "for (", with: "modules.push('later.js'); for (")),
            ("indexed assignment", loader.replacingOccurrences(of: "if (item.exists)", with: "modules[i] = 'other.js'; if (item.exists)")),
            ("compound assignment", loader.replacingOccurrences(of: "if (item.exists)", with: "modules[i] += '.bak'; if (item.exists)")),
            ("indexed update", loader.replacingOccurrences(of: "if (item.exists)", with: "modules[i]++; if (item.exists)")),
            ("prefix update", loader.replacingOccurrences(of: "if (item.exists)", with: "++modules[i]; if (item.exists)")),
            ("length assignment", loader.replacingOccurrences(of: "if (item.exists)", with: "modules.length = 0; if (item.exists)")),
            ("dynamic eval", loader.replacingOccurrences(of: "$.evalFile(item)", with: "$.evalFile(selectItem())")),
            ("nested scope", loader.replacingOccurrences(of: "var modules", with: "function inner() { return 1; } var modules"))
        ] {
            let (_, hints, candidate) = try make(changed)
            let seed = hints.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
            check("incomplete \(name) holds without guessing", candidate.select(seeds: [seed], scopeID: "desktop").passages.isEmpty)
        }
        let fake = "function boot(root) {\n var fake = \"var modules=['dead.js']; var item=new File(modules[i]); $.evalFile(item);\";\n /* $.evalFile(item); */\n}\n"
        let (_, fakeIndex, fakeContext) = try make(fake)
        let fakeSeed = fakeIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        check("strings/comments cannot create loader edges", fakeContext.select(seeds: [fakeSeed], scopeID: "desktop").passages.allSatisfy { $0.contextRole != "module" && $0.contextRole != "loader" })
        let (_, duplicateIndex, duplicateContext) = try make(extra: [file("desktop/alternate/alpha.js", module)])
        let duplicateSeed = duplicateIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        check("duplicate snapshot basename holds", duplicateContext.select(seeds: [duplicateSeed], scopeID: "desktop").passages.isEmpty)
        let comparisonLoader = loader.replacingOccurrences(of: "if (item.exists)", with: "if (modules[i] == 'alpha.js' || modules[i] === 'helper.js' || modules[i] !== 'other.js') { root = root; } if (item.exists)")
            + "function lazyLoad(root) { var item = findAtRuntime(root); $.evalFile(item); }\n"
        let (_, comparisonIndex, comparisonContext) = try make(comparisonLoader)
        let comparisonSeed = comparisonIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let compared = comparisonContext.select(seeds: [comparisonSeed], scopeID: "desktop")
        check("equality reads do not mutate array or poison valid loader", compared.passages.contains { $0.contextRole == "module" } && compared.unresolvedLoaderCount == 1)
        check("separate lazy loader remains explicit uncertainty", compared.note.contains("override behavior remain unverified"))
        let countHold = comparisonContext.select(seeds: [comparisonSeed], scopeID: "desktop", limit: 1)
        check("budget HOLD keeps scoped unresolved/navigation counts", countHold.unresolvedLoaderCount == compared.unresolvedLoaderCount && countHold.navigationIncompleteFileCount == compared.navigationIncompleteFileCount)
        let lazySeed = comparisonIndex.passages.lastIndex { $0.citation.path == "desktop/loader.js" }!
        let lazy = comparisonContext.select(seeds: [lazySeed, comparisonSeed], scopeID: "desktop")
        check("leading lazy-loader declaration not skipped for weaker module", lazy.passages.allSatisfy { $0.contextRole != "module" } && lazy.note.contains("dispatch is unresolved"))
        let tiedLoader = loader.replacingOccurrences(of: "'other.js'", with: "'other.js','callerA.js','callerB.js'")
        let (_, tiedIndex, tiedContext) = try make(tiedLoader, extra: [
            file("desktop/callerA.js", "var CallerA={};\nCallerA.run = function(v) { return Atlas.draw(v); };\n"),
            file("desktop/callerB.js", "var CallerB={};\nCallerB.run = function(v) { if (v.restricted) return false; return Atlas.draw(v); };\n")])
        let tieSeed = tiedIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let tieUI = tiedIndex.passages.firstIndex { $0.citation.path == "client/ui.html" }!
        let fit = tiedContext.select(seeds: [tieSeed, tieUI], scopeID: "desktop")
        check("tied callers both fit with answer-affecting guard and reserved UI", fit.passages.contains { $0.citation.path == "desktop/callerA.js" } && fit.passages.contains { $0.citation.path == "desktop/callerB.js" && $0.text.contains("v.restricted") } && fit.passages.last?.contextRole == "ui")
        let limited = tiedContext.select(seeds: [tieSeed, tieUI], scopeID: "desktop", limit: 4)
        check("reference boundary tie holds with explicit omissions", limited.passages.isEmpty && limited.omittedRelatedPaths.contains("desktop/callerA.js") && limited.omittedRelatedPaths.contains("desktop/callerB.js") && limited.note.contains("on hold"))
        let tightBytes = tiedContext.select(seeds: [tieSeed, tieUI], scopeID: "desktop", maximumBytes: module.utf8.count + loader.utf8.count + helper.utf8.count + 60)
        check("byte boundary tie never chooses lexical winner", tightBytes.passages.isEmpty && tightBytes.omittedRelatedPaths.contains("desktop/callerB.js"))
        let lateLoader = (0..<270).map { "function before\($0)() { return \($0); }\n" }.joined() + loader
        let (_, lateIndex, lateContext) = try make(lateLoader)
        let lateSeed = lateIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let lateSelection = lateContext.select(seeds: [lateSeed], scopeID: "desktop")
        check("late loader recovered beyond navigation256 without pretending full graph", lateIndex.fileCoverage[0]?.navigationComplete == false && lateIndex.fileCoverage[0]?.loaderInventoryComplete == true && lateIndex.loaderDeclarations.contains { $0.name == "boot" && $0.startLine > 256 } && lateSelection.passages.contains { $0.contextRole == "loader" } && lateSelection.note.contains("discovered within supported bounded scans"))
        var inventoryCap = RepositoryCodeIndex.Limits(); inventoryCap.inventoryDeclarations = 20
        let (_, cappedIndex, cappedContext) = try make(lateLoader, limits: inventoryCap)
        check("entrypoint inventory cap holds unseen late loader", cappedIndex.fileCoverage[0]?.loaderInventoryComplete == false && cappedContext.issue(for: "desktop") != nil && cappedContext.select(seeds: [0], scopeID: "desktop").passages.isEmpty)
        var scanCap = RepositoryCodeIndex.Limits(); scanCap.scanBytes = 8
        let (_, scanIndex, scanContext) = try make(limits: scanCap)
        check("scan budget recorded and loader completeness held", scanIndex.fileCoverage[0]?.reasons.contains("function-scan-budget") == true && scanContext.issue(for: "desktop") != nil)
        let oversizedLoader = loader.replacingOccurrences(of: " var modules", with: String(repeating: " // original loader context\n", count: 520) + " var modules")
        let (_, oversizedIndex, oversizedContext) = try make(oversizedLoader)
        check("oversized containing loader cannot masquerade as zero unresolved", oversizedIndex.fileCoverage[0]?.reasons.contains("function-span-limit") == true && oversizedContext.select(seeds: [0], scopeID: "desktop").note.contains("unseen loaders"))
        let guardedCaller = "var Caller={};\nCaller.run = function(v) { if (!gate(v)) return false; return Atlas.draw(v); };\nfunction gate(v) { return secondGate(v); }\nfunction gate(v) { return !v.ambiguousRestriction; }\nfunction secondGate(v) { return !v.guardRestriction; }\n" + String(repeating: "// large unrelated caller context\n", count: 25_000)
        let sparseLoader = loader.replacingOccurrences(of: "'other.js'", with: "'other.js','caller.js'")
        let (_, sparseIndex, sparseContext) = try make(sparseLoader, extra: [file("desktop/caller.js", guardedCaller)])
        let sparseSeed = sparseIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let sparse = sparseContext.select(seeds: [sparseSeed], scopeID: "desktop")
        check("oversized related module retains complete transitive/ambiguous guards", sparse.passages.contains { $0.citation.path == "desktop/caller.js" && $0.contextRole == "related_declarations" && $0.text.contains("v.ambiguousRestriction") && $0.text.contains("v.guardRestriction") } && sparse.passages.allSatisfy { $0.text.utf8.count < 512 * 1024 })
        let sparseHeld = sparseContext.select(seeds: [sparseSeed], scopeID: "desktop", limit: 2)
        check("ambiguous helper alternatives all retained or held", sparseHeld.passages.isEmpty && sparseHeld.omittedRelatedPaths.contains("desktop/caller.js"))
        let localA = "var LocalA=(function(){ var R={}; R.handle=function(v){ return R.guard(v); }; R.guard=function(v){ return !v.localRestriction; }; return R; })();\n"
        let localB = "var LocalB=(function(){ var R={}; R.handle=function(v){ return 'unrelated'; }; return R; })();\n"
        let localLoader = loader.replacingOccurrences(of: "'other.js'", with: "'other.js','localA.js','localB.js'")
        let (_, localIndex, localContext) = try make(localLoader, extra: [file("desktop/localA.js", localA),file("desktop/localB.js", localB)])
        let localSeed = localIndex.passages.firstIndex { $0.citation.path == "desktop/localA.js" }!
        let locals = localContext.select(seeds: [localSeed], scopeID: "desktop")
        check("identical IIFE-local R namespace cannot crosslink files", locals.passages.contains { $0.citation.path == "desktop/localA.js" } && !locals.passages.contains { $0.citation.path == "desktop/localB.js" })
        let clientText = (0..<270).map { "function clientBefore\($0)(){return \($0);}\n" }.joined() + "function wirePanel(){ if (!panelGuard()) return false; return 'visible'; }\nfunction panelGuard(){ return true; }\n"
        let htmlText = "<!-- <script src='js/evil.js'></script> -->\n<div data-fake=\"<script src='js/evil.js'>\">Panel</div>\n<script>var fake=\"<script src='js/evil.js'>\";</script>\n<script src='./js/main.js?v=1'></script>\n"
        let (_, clientIndex, clientContext) = try make(extra: [file("client/js/main.js", clientText),file("client/js/evil.js", "function fakeOwner(){return false;}\n")], html: htmlText)
        let clientSeed = clientIndex.passages.lastIndex { $0.citation.path == "client/js/main.js" }!
        let clientPrimary = clientIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let client = clientContext.select(seeds: [clientSeed, clientPrimary], scopeID: "desktop")
        check("ranked client owner recovered past256 with separate host primary", client.clientOwnerCount > 0 && client.passages.contains { $0.contextRole == "ui" && $0.citation.path == "client/js/main.js" && $0.citation.startLine > 256 && $0.text.contains("panelGuard") } && client.passages.contains { $0.contextRole == "module" && $0.citation.path == "desktop/alpha.js" })
        check("HTML comments/inline/attribute fake src cannot claim client ownership", client.htmlIssueCount == 0 && !client.passages.contains { $0.citation.path == "client/js/evil.js" })
        let shadowLoader = loader.replacingOccurrences(of: "'other.js'", with: "'other.js','shadow.js','genuine.js'")
        let (_, shadowIndex, shadowContext) = try make(shadowLoader, extra: [
            file("desktop/shadow.js", "var Caller={};\nCaller.run=function(v){return Atlas.draw(v);};\nfunction unrelated(Atlas){return Atlas.other();}\n"),
            file("desktop/genuine.js", "var Genuine={};\nGenuine.run=function(Atlas){return Atlas.draw({});};\n")])
        let shadowSeed = shadowIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let shadows = shadowContext.select(seeds: [shadowSeed], scopeID: "desktop")
        check("unrelated lexical parameter cannot shadow a global caller", shadows.passages.contains { $0.citation.path == "desktop/shadow.js" })
        check("actual caller parameter blocks cross-file namespace edge", !shadows.passages.contains { $0.citation.path == "desktop/genuine.js" })
        let irrelevantLoader = loader.replacingOccurrences(of: "'other.js'", with: "'other.js','unrelated.js'")
        let (_, relevantIndex, relevantContext) = try make(irrelevantLoader, extra: [file("desktop/unrelated.js", "var Outside={};\nOutside.run=function(v){return Atlas.exception(v);};\n")])
        let relevantSeed = relevantIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let relevant = relevantContext.select(seeds: [relevantSeed], scopeID: "desktop")
        check("whole primary does not nominate unrelated export callers", relevant.passages.contains { $0.text == module } && !relevant.passages.contains { $0.citation.path == "desktop/unrelated.js" })
        let uiTree = "// ranked navigation-only text\nvar defaults={label:'Panel'};\n\n\nfunction choose(){if(!firstGuard())return false;if(!secondGuard())return false;return setup();}\nfunction firstGuard(){return true;}\nfunction secondGuard(){return true;}\nfunction setup(){return eventBranch();}\nfunction eventBranch(){return deeperEvent();}\nfunction deeperEvent(){return true;}\n"
        let (_, treeIndex, treeContext) = try make(extra: [file("client/js/main.js", uiTree)], html: "<script src='js/main.js'></script>\n")
        let treeSeed = treeIndex.passages.firstIndex { $0.citation.path == "client/js/main.js" && $0.citation.startLine == 1 }!
        let ownerSeed = treeIndex.passages.firstIndex { $0.citation.path == "client/js/main.js" && $0.citation.startLine > 1 && $0.text.contains("function choose") }!
        let hostSeed = treeIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let tree = treeContext.select(seeds: [treeSeed, ownerSeed, hostSeed], scopeID: "desktop")
        let uiEvidence = tree.passages.filter { $0.contextRole == "ui" }.map(\.text).joined()
        check("navigation-only client seed does not poison executable owner", tree.clientNavigationSkippedCount > 0 && tree.clientOwnerCount > 0 && !tree.passages.isEmpty)
        check("client direct guards retained without recursive setup tree", uiEvidence.contains("function firstGuard") && uiEvidence.contains("function secondGuard") && !uiEvidence.contains("function deeperEvent") && tree.omittedClientCallNames.contains("eventBranch"))
        let largeClient = "function hugeClient(){\n" + String(repeating: " // preserved original\n", count: 530) + " return false;\n}\n"
        let (_, largeUIIndex, largeUIContext) = try make(extra: [file("client/js/main.js", largeClient)], html: "<script src='js/main.js'></script>\n")
        let largeUISeed = largeUIIndex.passages.firstIndex { $0.citation.path == "client/js/main.js" }!
        let largeHost = largeUIIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let largeUI = largeUIContext.select(seeds: [largeUISeed, largeHost], scopeID: "desktop")
        check("oversized executable client route explicitly unverified without global hold", largeUI.unverifiedClientOwnerCount > 0 && !largeUI.passages.isEmpty && largeUI.note.contains("unverified client routes"))
        let (_, orphanIndex, orphanContext) = try make(extra: [file("client/orphan.html", "<script src='js/orphan.js'></script>\n"),file("client/js/orphan.js", "function orphanOwner(){return false;}\n")])
        let orphanSeed = orphanIndex.passages.firstIndex { $0.citation.path == "client/js/orphan.js" }!
        let orphanHost = orphanIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let orphan = orphanContext.select(seeds: [orphanSeed, orphanHost], scopeID: "desktop")
        check("orphan HTML cannot claim active client script ownership", orphan.clientOwnerCount == 0 && !orphan.passages.contains { $0.citation.path == "client/js/orphan.js" })
        let upgradeLoader = loader.replacingOccurrences(of: "'other.js'", with: "'other.js','split.js','large.js'")
        let split = "var Split={};\nSplit.run=function(v){if(!left(v))return false;return Atlas.draw(v);};\n\n// middle original context\n\nfunction left(v){return !v.leftBlocked;}\n"
        let large = "var Large={};\nLarge.run=function(v){return Atlas.draw(v);};\n" + String(repeating: "// separate huge context\n", count: 30_000)
        let (_, upgradeIndex, upgradeContext) = try make(upgradeLoader, extra: [file("desktop/split.js", split),file("desktop/large.js", large)])
        let upgradeSeed = upgradeIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let upgraded = upgradeContext.select(seeds: [upgradeSeed], scopeID: "desktop", limit: 6)
        check("individual whole upgrade retains cheap original context beside large sparse caller", upgraded.passages.contains { $0.citation.path == "desktop/split.js" && $0.contextRole == "module" && $0.text == split } && upgraded.passages.contains { $0.citation.path == "desktop/large.js" && $0.contextRole == "related_declarations" })
        let partialLoader = loader.replacingOccurrences(of: "'other.js'", with: "'other.js','partial.js'")
        let cappedCaller = "var Partial={};\nPartial.run=function(v){return Atlas.draw(v);};\n" + (0..<25).map { "function intermediate\($0)(){return \($0);}\n" }.joined() + "Partial.late=function(v){if(v.blocked)return false;return Atlas.draw(v);};\n"
        var smallInventory = RepositoryCodeIndex.Limits(); smallInventory.inventoryDeclarations = 20
        let (_, wholeCapIndex, wholeCapContext) = try make(partialLoader, extra: [file("desktop/partial.js", cappedCaller)], limits: smallInventory)
        let capSeed = wholeCapIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let wholeCap = wholeCapContext.select(seeds: [capSeed], scopeID: "desktop")
        check("whole-file upgrade clears missing raw source but never scan graph uncertainty", wholeCap.passages.contains { $0.text == cappedCaller } && wholeCap.partialSourcePaths["desktop/partial.js"] == nil && wholeCap.incompleteSupportedScanPaths["desktop/partial.js"]?.contains("declaration-inventory-cap") == true && wholeCap.note.contains("not exhaustive"))
        let (_, cappedClientIndex, cappedClientContext) = try make(extra: [file("client/js/main.js", cappedCaller)], limits: smallInventory, html: "<script src='js/main.js'></script>\n")
        let cappedClientSeed = cappedClientIndex.passages.firstIndex { $0.citation.path == "client/js/main.js" }!
        let cappedHostSeed = cappedClientIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let cappedClient = cappedClientContext.select(seeds: [cappedClientSeed, cappedHostSeed], scopeID: "desktop")
        check("small partial client file can upgrade whole text as uncached UI", cappedClient.passages.contains { $0.text == cappedCaller && $0.contextRole == "ui" } && cappedClient.partialSourcePaths["client/js/main.js"] == nil && cappedClient.incompleteSupportedScanPaths["client/js/main.js"] != nil)
        let largeCapped = cappedCaller + String(repeating: "// bounded original context\n", count: 24_000)
        let (_, fragmentIndex, fragmentContext) = try make(partialLoader, extra: [file("desktop/partial.js", largeCapped)], limits: smallInventory)
        let fragmentSeed = fragmentIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let fragment = fragmentContext.select(seeds: [fragmentSeed], scopeID: "desktop")
        check("late undiscovered caller gives exact partial path/reasons and needs-check", !fragment.passages.isEmpty && fragment.partialSourcePaths["desktop/partial.js"]?.contains("declaration-inventory-cap") == true && fragment.note.contains("unknown callers/guards may exist") && fragment.note.contains("needs_check") && fragment.note.contains("not evidence of absence"))
        for badHTML in ["<script src='../server/api.js'></script>", "<script src='js/missing.js'></script>", "<script src='js/main.js' src='js/evil.js'></script>"] {
            let (_, badIndex, badContext) = try make(html: badHTML)
            let seed = badIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
            let result = badContext.select(seeds: [seed], scopeID: "desktop")
            check("missing/escaped/ambiguous HTML source reported without invented owner", result.htmlIssueCount > 0 && result.clientOwnerCount == 0 && result.note.contains("host-loader-only"))
        }
        let (_, hugeIndex, hugeContext) = try make(huge: true)
        let hugeSeed = hugeIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
        let bounded = hugeContext.select(seeds: [hugeSeed], scopeID: "desktop")
        check("oversized module uses complete declaration fallback", !bounded.passages.isEmpty && bounded.passages.first?.text.contains("return Guard.allow(value); };") == true && bounded.passages.allSatisfy { $0.contextRole == nil })
        let serverSeed = index.passages.firstIndex { $0.citation.path == "server/api.js" }!
        check("server retains its own complete declaration route", context.select(seeds: [serverSeed], scopeID: "server").passages.allSatisfy { $0.citation.path.hasPrefix("server/") })
        check("unknown scope cannot pick runtime", context.select(seeds: [seed], scopeID: "unknown").passages.isEmpty)
        for (text, reason) in [("var Guard={};\nGuard.allow=(value)=>{if(value.blocked)return false;return value.ready;};\n", "unsupported-arrow-function"), ("var Guard={allow(value){if(value.blocked)return false;return value.ready;}};\n", "unsupported-concise-method-syntax")] {
            let (_, unsupportedIndex, unsupportedContext) = try make(helperText: text)
            let sourceSeed = unsupportedIndex.passages.firstIndex { $0.citation.path == "desktop/alpha.js" }!
            let unsupported = unsupportedContext.select(seeds: [sourceSeed], scopeID:"desktop")
            check("unparsed related guard exposes exact scan gap and needs-check", unsupported.incompleteSupportedScanPaths["desktop/helper.js"]?.contains(reason) == true && unsupported.note.contains("needs_check") && !unsupported.passages.isEmpty)
        }
        let primaryWithArrow = "var Primary={};\nPrimary.run=function(v){return Guard.allow(v) && guard(v);};\nconst guard=(v)=>!v.blocked;\n"
        let arrowLoader = loader.replacingOccurrences(of:"'other.js'",with:"'other.js','primary.js'")
        let (_, primaryArrowIndex, primaryArrowContext) = try make(arrowLoader,extra:[file("desktop/primary.js",primaryWithArrow)])
        let primaryArrowSeed = primaryArrowIndex.passages.firstIndex { $0.citation.path == "desktop/primary.js" }!
        let primaryArrow = primaryArrowContext.select(seeds:[primaryArrowSeed],scopeID:"desktop")
        check("whole original primary clears only text omission despite unsupported syntax", primaryArrow.passages.first?.text == primaryWithArrow && primaryArrow.incompleteSupportedScanPaths["desktop/primary.js"] != nil && primaryArrow.partialSourcePaths["desktop/primary.js"] == nil)
        check("primary file precedes lexically earlier related modules", primaryArrow.passages.first?.citation.path == "desktop/primary.js" && primaryArrow.passages.contains { $0.citation.path == "desktop/helper.js" })
        print("MODULE CONTEXT: \(checks) checks; \(failures) failures; fictional source only; no native/model acceptance")
        if failures > 0 { exit(1) }
    }
}
