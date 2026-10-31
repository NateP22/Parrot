import Foundation
import Darwin
import CryptoKit

enum ReviewedSelectorJournalChecks {
    static func run(_ check:(String,Bool)->Void) {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("selector-journal-"+UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            let output=directory.appendingPathComponent("records.jsonl")
            do {
                let journal=try ReviewedSelectorJournal(url:output,header:["type":"header"],expectedRows:1)
                var status=stat()
                check("selector journal is private0600",lstat(output.path,&status)==0 && status.st_mode & 0o777 == 0o600)
                try journal.append(["type":"row","id":"fictional-case"])
                let before=try Data(contentsOf:output)
                do { _=try ReviewedSelectorJournal(url:output,header:["type":"other"],expectedRows:1); check("selector journal never overwrites",false) }
                catch { check("selector journal never overwrites",(try? Data(contentsOf:output))==before) }
                let receipt=try journal.finish()
                let completed=try Data(contentsOf:output)
                check("selector journal completion receipt binds exact persisted bytes",receipt.rows==1 && receipt.bytes==completed.count && receipt.sha256==SHA256.hash(data:completed).map{String(format:"%02x",$0)}.joined())
                check("selector completion verifier accepts actual successful receipt",ReviewedSelectorJournal.verifies(receipt,at:output))
                var tampered=completed;tampered[0] ^= 1
                try tampered.write(to:output)
                check("selector completion verifier rejects same-length file tamper",!ReviewedSelectorJournal.verifies(receipt,at:output))
                try completed.write(to:output)
                let wrong=ReviewedSelectorJournal.Completion(rows:receipt.rows,bytes:receipt.bytes,sha256:String(repeating:"0",count:64))
                check("selector completion verifier rejects wrong expected hash",!ReviewedSelectorJournal.verifies(wrong,at:output))
                let lines=String(decoding:completed,as:UTF8.self).split(separator:"\n")
                let footer=try JSONSerialization.jsonObject(with:Data(lines.last!.utf8)) as? [String:Any]
                check("selector journal completes with exact count and unscored footer",lines.count==3 && footer?["type"] as? String=="footer" && footer?["rows"] as? Int==1 && footer?["complete"] as? Bool==true && footer?["nativeAcceptance"] as? Bool==false && footer?["scored"] as? Bool==false)
                do { try journal.append(["late":"row"]); check("selector journal rejects rows after completion",false) }
                catch { check("selector journal rejects rows after completion",true) }
            } catch { check("selector journal valid completion",false) }
            do {
                let path=directory.appendingPathComponent("partial.jsonl")
                let journal=try ReviewedSelectorJournal(url:path,header:["type":"header"],expectedRows:2)
                try journal.append(["type":"row"])
                do { try journal.finish(); check("selector journal cannot complete missing rows",false) }
                catch { check("selector journal cannot complete missing rows",true) }
                let bytes=String(decoding:try Data(contentsOf:path),as:UTF8.self)
                check("selector journal partial remains without footer",!bytes.contains("footer") && !bytes.contains("complete"))
            } catch { check("selector journal partial fixture",false) }
            do {
                let journal=try ReviewedSelectorJournal(url:directory.appendingPathComponent("bounded.jsonl"),header:["type":"header"],expectedRows:1)
                do { try journal.append(["text":String(repeating:"x",count:65_537)]); check("selector journal bounds each encoded row",false) }
                catch { check("selector journal bounds each encoded row",true) }
                do { try journal.append(["type":"row"]); try journal.finish(); check("selector journal failure stays incomplete",false) }
                catch { check("selector journal failure stays incomplete",true) }
            } catch { check("selector journal bounded fixture",false) }
            do {
                let path=directory.appendingPathComponent("sync-failure.jsonl")
                var syncCount=0
                let journal=try ReviewedSelectorJournal(url:path,header:["type":"header"],expectedRows:1,synchronize:{ fd in
                    syncCount += 1
                    if syncCount==3 { errno=EIO;return -1 }
                    return Darwin.fsync(fd)
                })
                try journal.append(["type":"row"])
                do { try journal.finish();check("selector journal reports final-sync IO failure",false) }
                catch { check("selector journal reports final-sync IO failure",true) }
                let data=String(decoding:try Data(contentsOf:path),as:UTF8.self)
                check("selector journal rolls back footer after final-sync failure",!data.contains("\"complete\":true") && !data.contains("footer"))
            } catch { check("selector journal final-sync fixture",false) }
            let link=directory.appendingPathComponent("symlink.jsonl")
            try FileManager.default.createSymbolicLink(at:link,withDestinationURL:output)
            let before=try? Data(contentsOf:output)
            do { _=try ReviewedSelectorJournal(url:link,header:["type":"header"],expectedRows:1); check("selector journal rejects linked output",false) }
            catch { check("selector journal rejects linked output",(try? Data(contentsOf:output))==before) }
            do { _=try ReviewedSelectorJournal(url:directory.appendingPathComponent("empty.jsonl"),header:["type":"header"],expectedRows:0);check("selector journal rejects zero planned rows",false) }
            catch { check("selector journal rejects zero planned rows",true) }
        } catch { check("selector journal fixture setup",false) }
    }
}
