import Foundation
import Darwin

/// Pilot component preparation; never opens normal KB/store, key or provider.
enum ReviewedSelectorInput {
    enum Failure: Error, Equatable { case invalidInput, unsafePath, tooLarge, outputExists }
    struct Artifact: Decodable { let path: String; let sha256: String }
    struct SourceFile: Decodable { let sourceID: String; let path: String; let sha256: String }
    struct Unit: Decodable { let id: String; let digest: String }
    struct Manifest: Decodable {
        let schema: Int
        let buildCommit: String
        let catalog: Artifact
        let cases: Artifact
        let sources: [SourceFile]
        let units: [Unit]
        let modes: [String]
        let resultPath: String
    }
    /// Unknown fixture annotations are intentionally not retained.
    struct ExecutionCase: Codable {
        let id: String
        let question: String
        let previous: String
    }
    struct FileReceipt: Codable {
        let path: String
        let bytes: Int
        let sha256: String
    }
    struct Prepared {
        let snapshot: ReviewedAnswerCatalog.Snapshot
        let cases: [ExecutionCase]
        let modes: [String]
        let manifestSHA256: String
        let catalogSHA256: String
        let casesSHA256: String
        let expectedBuildCommit: String
        let groupURL: URL
        let resultURL: URL
        let files: [FileReceipt]
    }

    static func prepare(manifestURL: URL, allowedRoot: URL) throws -> Prepared {
        let root = allowedRoot.standardizedFileURL
        guard root.isFileURL, manifestURL.isFileURL,
              manifestURL.path == manifestURL.standardizedFileURL.path else { throw Failure.unsafePath }
        // Foundation's app-support base is trusted; app-owned descendants cannot redirect it.
        try canonical(root)
        let canonicalRoot = root
        let supplied = manifestURL.path
        let prefix = [root.path, canonicalRoot.path].first { supplied.hasPrefix($0+"/") }
        guard let prefix else { throw Failure.unsafePath }
        let relative = String(supplied.dropFirst(prefix.count+1))
        try validateRelative(relative)
        let manifest = canonicalRoot.appendingPathComponent(relative)
        let group = manifest.deletingLastPathComponent()
        guard group.path != canonicalRoot.path else { throw Failure.unsafePath }
        try canonical(manifest)
        let manifestData = try readRegular(manifest, cap:262_144)
        let m = try JSONDecoder().decode(Manifest.self,from:manifestData)
        guard m.schema == 1, m.buildCommit.range(of:"^[0-9a-f]{40}$",options:.regularExpression) != nil,
              (1...16).contains(m.sources.count), (1...256).contains(m.units.count),
              Set(m.sources.map(\.sourceID)).count == m.sources.count,
              Set(m.units.map(\.id)).count == m.units.count,
              !m.modes.isEmpty, m.modes.count <= 2, Set(m.modes).count == m.modes.count,
              Set(m.modes).isSubset(of:Set(["isolated","rolling"])) else { throw Failure.invalidInput }
        func path(_ relative:String) throws -> URL {
            try validateRelative(relative)
            let value = group.appendingPathComponent(relative)
            try canonical(value)
            return value
        }
        let catalogURL = try path(m.catalog.path), casesURL = try path(m.cases.path)
        let sourceURLs = try m.sources.map { try path($0.path) }
        let result = try path(m.resultPath)
        var info = stat()
        if lstat(result.path,&info) == 0 { throw Failure.outputExists }
        guard errno == ENOENT else { throw Failure.unsafePath }
        let parent = result.deletingLastPathComponent()
        let parentValues = try parent.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else { throw Failure.unsafePath }
        let inputs = [manifest,catalogURL,casesURL]+sourceURLs
        guard Set(inputs.map(\.path)).count == inputs.count,
              !inputs.contains(where:{$0.path == result.path}) else { throw Failure.invalidInput }

        let catalogData = try readRegular(catalogURL,cap:1_048_576)
        let casesData = try readRegular(casesURL,cap:262_144)
        guard isSHA(m.catalog.sha256), isSHA(m.cases.sha256),
              ReviewedAnswerCatalog.sha256(catalogData) == m.catalog.sha256,
              ReviewedAnswerCatalog.sha256(casesData) == m.cases.sha256 else { throw Failure.invalidInput }
        let catalog = try ReviewedAnswerCatalog.decode(catalogData)
        guard catalog.sources.count == m.sources.count, catalog.answers.count == m.units.count,
              Set(catalog.sources.map(\.id)) == Set(m.sources.map(\.sourceID)),
              Set(catalog.answers.map(\.id)) == Set(m.units.map(\.id)) else { throw Failure.invalidInput }
        let sourceMap = Dictionary(uniqueKeysWithValues:catalog.sources.map {($0.id,$0)})
        let unitMap = Dictionary(uniqueKeysWithValues:catalog.answers.map {($0.id,$0.contentDigest)})
        guard m.units.allSatisfy({isSHA($0.digest) && unitMap[$0.id] == $0.digest}) else { throw Failure.invalidInput }
        var receipts = [
            FileReceipt(path:String(manifest.path.dropFirst(group.path.count+1)),bytes:manifestData.count,sha256:ReviewedAnswerCatalog.sha256(manifestData)),
            FileReceipt(path:m.catalog.path,bytes:catalogData.count,sha256:m.catalog.sha256),
            FileReceipt(path:m.cases.path,bytes:casesData.count,sha256:m.cases.sha256)
        ]
        var documents: [KBDocument] = []
        for (index,entry) in m.sources.enumerated() {
            guard let source = sourceMap[entry.sourceID], isSHA(entry.sha256),
                  entry.sha256 == source.sha256 else { throw Failure.invalidInput }
            let bytes = try readRegular(sourceURLs[index],cap:524_288)
            let hash = ReviewedAnswerCatalog.sha256(bytes)
            guard hash == entry.sha256, bytes == Data(source.text.utf8) else { throw Failure.invalidInput }
            documents.append(KBDocument(name:source.name,chunkCount:1,addedAt:Date(timeIntervalSince1970:0),
                                        scope:.all,contentSHA256:hash))
            receipts.append(FileReceipt(path:entry.path,bytes:bytes.count,sha256:hash))
        }
        let cases = try JSONDecoder().decode([ExecutionCase].self,from:casesData)
        guard (1...128).contains(cases.count), Set(cases.map(\.id)).count == cases.count,
              cases.allSatisfy({
                  !$0.id.isEmpty && $0.id.count <= 80 &&
                  $0.id.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]*$",options:.regularExpression) != nil &&
                  !$0.question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
                  $0.question.count <= 4_000 && $0.previous.count <= 16_000
              }) else { throw Failure.invalidInput }
        try inventory(group:group,inputs:inputs,result:result)
        let snapshot = catalog.admitted(documents:documents,folders:[],profileID:nil)
        guard snapshot.admissionIssues.isEmpty,
              Set(snapshot.sources.map(\.id)) == Set(catalog.sources.map(\.id)),
              snapshot.answers.count == catalog.answers.count,
              snapshot.answers.allSatisfy({unitMap[$0.id] == $0.contentDigest}) else { throw Failure.invalidInput }
        return Prepared(snapshot:snapshot,cases:cases,modes:m.modes,
                        manifestSHA256:ReviewedAnswerCatalog.sha256(manifestData),
                        catalogSHA256:m.catalog.sha256,casesSHA256:m.cases.sha256,
                        expectedBuildCommit:m.buildCommit,groupURL:group,resultURL:result,files:receipts)
    }

    private static func isSHA(_ value:String) -> Bool {
        value.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil
    }
    private static func validateRelative(_ path:String) throws {
        let parts = path.components(separatedBy:"/")
        guard !path.isEmpty, path.utf8.count <= 240,
              path.range(of:"^[A-Za-z0-9][A-Za-z0-9._/-]*$",options:.regularExpression) != nil,
              parts.allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else { throw Failure.unsafePath }
    }
    private static func canonical(_ url:URL) throws {
        guard url.path == url.standardizedFileURL.path,
              url.path == url.resolvingSymlinksInPath().path else { throw Failure.unsafePath }
    }

    /// Bounds are checked on the opened regular file before allocating data.
    private static func readRegular(_ url:URL,cap:Int) throws -> Data {
        try canonical(url)
        let fd = open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafePath }
        defer { close(fd) }
        var first = stat()
        guard fstat(fd,&first) == 0, (first.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              first.st_size >= 0 else { throw Failure.unsafePath }
        guard first.st_size <= cap else { throw Failure.tooLarge }
        var data = Data()
        data.reserveCapacity(Int(first.st_size))
        var buffer = [UInt8](repeating:0,count:65_536)
        while true {
            let limit = min(buffer.count,cap+1-data.count)
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,limit) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Failure.invalidInput
            }
            if count == 0 { break }
            data.append(contentsOf:buffer.prefix(count))
            guard data.count <= cap else { throw Failure.tooLarge }
        }
        var last = stat(), named = stat()
        guard fstat(fd,&last) == 0, lstat(url.path,&named) == 0,
              first.st_dev == last.st_dev, first.st_ino == last.st_ino,
              last.st_dev == named.st_dev, last.st_ino == named.st_ino,
              first.st_size == last.st_size, data.count == last.st_size,
              first.st_mtimespec.tv_sec == last.st_mtimespec.tv_sec,
              first.st_mtimespec.tv_nsec == last.st_mtimespec.tv_nsec else { throw Failure.invalidInput }
        return data
    }

    private static func inventory(group:URL,inputs:[URL],result:URL) throws {
        let expected = Set(inputs.map(\.path))
        var directories = Set<String>()
        for file in inputs+[result] {
            var parent = file.deletingLastPathComponent()
            while parent.path != group.path {
                guard parent.path.hasPrefix(group.path+"/") else { throw Failure.unsafePath }
                directories.insert(parent.path); parent.deleteLastPathComponent()
            }
        }
        var enumerationFailed = false
        guard let scan = FileManager.default.enumerator(at:group,
            includingPropertiesForKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey],
            options:[],errorHandler:{_,_ in enumerationFailed = true; return false}) else { throw Failure.invalidInput }
        var seen = Set<String>(), count = 0
        for case let enumerated as URL in scan {
            // Foundation enumerates system /var aliases as /private/var on macOS.
            let url = enumerated.standardizedFileURL
            count += 1
            guard count <= 64 else { throw Failure.tooLarge }
            try canonical(url)
            let flags = try url.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey])
            guard flags.isSymbolicLink != true else { throw Failure.unsafePath }
            if flags.isDirectory == true {
                guard directories.contains(url.path) else { throw Failure.invalidInput }
            } else {
                guard flags.isRegularFile == true, expected.contains(url.path) else { throw Failure.invalidInput }
                seen.insert(url.path)
            }
        }
        guard !enumerationFailed, seen == expected else { throw Failure.invalidInput }
    }
}
