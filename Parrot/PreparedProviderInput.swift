import Foundation
import CoreFoundation
import CryptoKit
import Darwin

/// Frozen developer comparison only. Declared repository provenance is NOT
/// reverified from the original repository by this packet loader.
enum PreparedProviderInput {
    enum Failure: Error { case invalid, unsafePath, tooLarge, outputExists }
    struct Row {
        let ordinal: Int, caseID: String, variant: String, declaredOriginalPayloadSHA256: String
        let declaredLogicalBytes: Int
        let stableContextSHA256: String, wireSHA256: String
        let wireData: Data, body: [String: Any]
    }
    struct Prepared {
        let rows: [Row], group: URL, resultURL: URL, buildCommit: String
        let manifestSHA256: String, packetSHA256: String
        let declaredRepositoryCommit: String, declaredSourcePacketSHA256: String
        let declaredWireQualificationSHA256: String
    }
    static func sha(_ data: Data) -> String { SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined() }
    private static func hash(_ value: Any?, count: Int = 64) -> String? {
        guard let value=value as? String,
              value.range(of:"^[0-9a-f]{\(count)}$",options:.regularExpression) != nil else {return nil}
        return value
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite,n.doubleValue >= 0,n.doubleValue <= 16_777_216,
              n.doubleValue.rounded(.towardZero)==n.doubleValue else {return nil}
        return n.intValue
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let s=value as? String,s.count<=80,
              s.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]*$",options:.regularExpression) != nil else {return nil}
        return s
    }
    private static func keys(_ object:[String:Any],_ expected:[String])->Bool {Set(object.keys)==Set(expected)}
    private static func canonical(_ url:URL) throws {
        guard url.isFileURL,url.path==url.standardizedFileURL.path,
              url.path==url.resolvingSymlinksInPath().path else {throw Failure.unsafePath}
    }
    private static func privateDirectory(_ url:URL) throws {
        try canonical(url)
        var s=stat()
        guard lstat(url.path,&s)==0,(s.st_mode & mode_t(S_IFMT))==mode_t(S_IFDIR),
              s.st_mode & 0o777==0o700,s.st_uid==geteuid() else {throw Failure.unsafePath}
    }
    private static func read(_ url:URL,cap:Int) throws ->Data {
        try canonical(url)
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw Failure.unsafePath};defer {close(fd)}
        var first=stat(),last=stat(),named=stat()
        guard fstat(fd,&first)==0,(first.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG),
              first.st_mode & 0o777==0o600,first.st_uid==geteuid(),first.st_nlink==1,
              first.st_size>=0 else {throw Failure.unsafePath}
        guard first.st_size<=cap else {throw Failure.tooLarge}
        var data=Data(),buffer=[UInt8](repeating:0,count:65536)
        data.reserveCapacity(Int(first.st_size))
        while true {
            let n=buffer.withUnsafeMutableBytes {Darwin.read(fd,$0.baseAddress,min($0.count,cap+1-data.count))}
            if n<0 && errno==EINTR {continue}
            guard n>=0 else {throw Failure.invalid};if n==0 {break}
            data.append(contentsOf:buffer.prefix(n));guard data.count<=cap else {throw Failure.tooLarge}
        }
        guard fstat(fd,&last)==0,lstat(url.path,&named)==0,
              first.st_dev==last.st_dev,first.st_ino==last.st_ino,last.st_dev==named.st_dev,last.st_ino==named.st_ino,
              last.st_mode==first.st_mode,last.st_uid==first.st_uid,last.st_nlink==1,
              first.st_size==last.st_size,data.count==last.st_size,
              first.st_mtimespec.tv_sec==last.st_mtimespec.tv_sec,
              first.st_mtimespec.tv_nsec==last.st_mtimespec.tv_nsec else {throw Failure.invalid}
        return data
    }
    static func prepare(manifestURL:URL,allowedRoot:URL,model:String,expectedPacketSHA256:String) throws ->Prepared {
        guard hash(expectedPacketSHA256) != nil else {throw Failure.invalid}
        try privateDirectory(allowedRoot);try canonical(manifestURL)
        let group=manifestURL.deletingLastPathComponent()
        guard manifestURL.lastPathComponent=="manifest.json",group.deletingLastPathComponent().path==allowedRoot.path,
              identifier(group.lastPathComponent) != nil else {throw Failure.unsafePath}
        try privateDirectory(group)
        let packetURL=group.appendingPathComponent("requests.json"),resultURL=group.appendingPathComponent("results.jsonl")
        var out=stat()
        if lstat(resultURL.path,&out)==0 {throw Failure.outputExists}
        guard errno==ENOENT else {throw Failure.unsafePath}
        let names=try FileManager.default.contentsOfDirectory(atPath:group.path)
        guard Set(names)==Set(["manifest.json","requests.json"]),names.count==2 else {throw Failure.invalid}
        let manifestData=try read(manifestURL,cap:65536)
        guard let m=try JSONSerialization.jsonObject(with:manifestData) as? [String:Any],
              keys(m,["schema","build_commit","packet","wire_rows","source_repository_commit","source_packet_sha256","wire_qualification_sha256"]),
              integer(m["schema"])==1,let build=hash(m["build_commit"],count:40),
              let repo=hash(m["source_repository_commit"],count:40),let source=hash(m["source_packet_sha256"]),
              let qualification=hash(m["wire_qualification_sha256"]),
              let packet=m["packet"] as? [String:Any],keys(packet,["path","sha256"]),
              packet["path"] as? String=="requests.json",let packetSHA=hash(packet["sha256"]),packetSHA==expectedPacketSHA256,
              let mapping=m["wire_rows"] as? [[String:Any]],mapping.count==15 else {throw Failure.invalid}
        let data=try read(packetURL,cap:8*1024*1024)
        guard sha(data)==packetSHA,let input=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],
              input.count==15 else {throw Failure.invalid}
        var rows:[Row]=[],pairs=Set<String>(),cases=Set<String>(),variants=Set<String>()
        var questions:[String:String]=[:],systemSHA:String?
        for (i,value) in input.enumerated() {
            let w=mapping[i]
            guard keys(value,["case_id","variant","payload_sha256","bytes","stable_context_sha256","body"]),
                  keys(w,["ordinal","case_id","variant","payload_sha256","wire_sha256","wire_bytes"]),
                  integer(w["ordinal"])==i+1,let id=identifier(value["case_id"]),let variant=identifier(value["variant"]),
                  w["case_id"] as? String==id,w["variant"] as? String==variant,
                  let original=hash(value["payload_sha256"]),w["payload_sha256"] as? String==original,
                  let stable=hash(value["stable_context_sha256"]),let declaredBytes=integer(value["bytes"]),
                  declaredBytes>0,declaredBytes<=RepositoryPromptCache.maximumEncodedBytes,
                  let expectedWire=hash(w["wire_sha256"]),let expectedBytes=integer(w["wire_bytes"]),
                  let body=value["body"] as? [String:Any],
                  keys(body,["model","max_tokens","temperature","system","cache_control","messages"]),
                  body["model"] as? String==model,integer(body["max_tokens"])==220,integer(body["temperature"])==0,
                  let topCache=body["cache_control"] as? [String:String],topCache==["type":"ephemeral"],
                  let system=body["system"] as? [[String:Any]],system.count==1,
                  keys(system[0],["type","text","cache_control"]),system[0]["type"] as? String=="text",
                  let prompt=system[0]["text"] as? String,!prompt.isEmpty,prompt.utf8.count<=8192,
                  system[0]["cache_control"] as? [String:String]==["type":"ephemeral","ttl":"1h"],
                  let messages=body["messages"] as? [[String:Any]],messages.count==3,
                  messages.allSatisfy({keys($0,["role","content"])}),
                  messages.map({$0["role"] as? String})==["user","assistant","user"],
                  messages[1]["content"] as? String=="Original code context loaded.",
                  let question=messages[2]["content"] as? String,!question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  question.utf8.count<=4000,let blocks=messages[0]["content"] as? [[String:Any]],blocks.count==2,
                  keys(blocks[0],["type","text","cache_control"]),blocks[0]["type"] as? String=="text",
                  blocks[0]["cache_control"] as? [String:String]==["type":"ephemeral","ttl":"1h"],
                  let context=blocks[0]["text"] as? String,sha(Data(context.utf8))==stable,
                  keys(blocks[1],["type","text"]),blocks[1]["type"] as? String=="text",
                  blocks[1]["text"] as? String=="Acknowledge the original code context." else {throw Failure.invalid}
            let common=sha(try JSONSerialization.data(withJSONObject:system,options:.sortedKeys))
            if let prior=systemSHA,prior != common {throw Failure.invalid};systemSHA=common
            if let prior=questions[id],prior != question {throw Failure.invalid};questions[id]=question
            guard pairs.insert(id+"|"+variant).inserted else {throw Failure.invalid}
            cases.insert(id);variants.insert(variant)
            let wire=try RepositoryPromptCache.encodedBody(body,required:true)
            guard wire.count==expectedBytes,sha(wire)==expectedWire else {throw Failure.invalid}
            rows.append(Row(ordinal:i+1,caseID:id,variant:variant,declaredOriginalPayloadSHA256:original,
                            declaredLogicalBytes:declaredBytes,
                            stableContextSHA256:stable,wireSHA256:expectedWire,wireData:wire,body:body))
        }
        guard cases.count==3,variants.count==5,pairs.count==15 else {throw Failure.invalid}
        // Recheck the full group after all reads; no hidden oracle/scoring files.
        guard Set(try FileManager.default.contentsOfDirectory(atPath:group.path))==Set(names) else {throw Failure.invalid}
        return Prepared(rows:rows,group:group,resultURL:resultURL,buildCommit:build,
                        manifestSHA256:sha(manifestData),packetSHA256:packetSHA,
                        declaredRepositoryCommit:repo,declaredSourcePacketSHA256:source,
                        declaredWireQualificationSHA256:qualification)
    }
}
