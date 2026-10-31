import Foundation
import Darwin
import CryptoKit

/// Private component records. Consumers must match a returned completion receipt
/// to the file hash; a footer alone never proves successful execution/durability.
final class ReviewedSelectorJournal {
    enum Failure: Error { case invalidInput, unavailable, closed, tooLarge }
    struct Completion: Encodable { let rows:Int; let bytes:Int; let sha256:String }
    /// Readback gate for a receipt returned by finish(), never proof of its
    /// origin, semantic accuracy, provider authentication or native delivery.
    static func verifies(_ receipt:Completion,at url:URL) -> Bool {
        guard (1...256).contains(receipt.rows),(1...16_777_216).contains(receipt.bytes),
              receipt.sha256.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil,
              url.isFileURL,url.path==url.standardizedFileURL.path,
              url.path==url.resolvingSymlinksInPath().path else { return false }
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd >= 0 else { return false };defer { close(fd) }
        var first=stat(),last=stat(),named=stat()
        guard fstat(fd,&first)==0,(first.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG),
              first.st_mode & 0o777==0o600,first.st_size==receipt.bytes else { return false }
        var data=Data(),buffer=[UInt8](repeating:0,count:65_536)
        data.reserveCapacity(receipt.bytes)
        while true {
            let count=buffer.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress,min($0.count,receipt.bytes+1-data.count)) }
            if count < 0 && errno==EINTR { continue }
            guard count >= 0 else { return false }
            if count==0 { break }
            data.append(contentsOf:buffer.prefix(count))
            guard data.count<=receipt.bytes else { return false }
        }
        guard fstat(fd,&last)==0,lstat(url.path,&named)==0,data.count==receipt.bytes,
              first.st_dev==last.st_dev,first.st_ino==last.st_ino,last.st_size==receipt.bytes,
              last.st_dev==named.st_dev,last.st_ino==named.st_ino,
              first.st_mtimespec.tv_sec==last.st_mtimespec.tv_sec,
              first.st_mtimespec.tv_nsec==last.st_mtimespec.tv_nsec,
              SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==receipt.sha256 else { return false }
        let lines=data.split(separator:10,omittingEmptySubsequences:false)
        guard lines.count==receipt.rows+3,lines.last?.isEmpty==true,
              lines.dropLast().allSatisfy({!$0.isEmpty}),
              let footer=(try? JSONSerialization.jsonObject(with:Data(lines[lines.count-2]))) as? [String:Any],
              Set(footer.keys)==Set(["type","complete","nativeAcceptance","scored","rows"]),
              footer["type"] as? String=="footer",footer["complete"] as? Bool==true,
              footer["nativeAcceptance"] as? Bool==false,footer["scored"] as? Bool==false,
              footer["rows"] as? Int==receipt.rows else { return false }
        return true
    }
    private var descriptor: Int32 = -1
    private let expectedRows: Int
    private let url:URL
    private var rows=0, bytes=0
    private var failed=false
    private let synchronize:(Int32)->Int32

    init<T: Encodable>(url: URL, header: T, expectedRows: Int,
                       synchronize:@escaping(Int32)->Int32=Darwin.fsync) throws {
        self.expectedRows=expectedRows
        self.url=url
        self.synchronize=synchronize
        guard (1...256).contains(expectedRows),url.isFileURL,
              url.path==url.standardizedFileURL.path,
              url.path==url.resolvingSymlinksInPath().path else { throw Failure.invalidInput }
        descriptor=open(url.path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard descriptor >= 0 else { throw Failure.unavailable }
        do {
            var opened=stat(),named=stat()
            guard fchmod(descriptor,0o600)==0,fstat(descriptor,&opened)==0,lstat(url.path,&named)==0,
                  opened.st_dev==named.st_dev,opened.st_ino==named.st_ino,
                  (opened.st_mode & mode_t(S_IFMT))==mode_t(S_IFREG) else { throw Failure.unavailable }
            try write(header)
        } catch { close(descriptor);descriptor = -1;throw error }
    }
    deinit { if descriptor >= 0 { close(descriptor) } }

    func append<T: Encodable>(_ row: T) throws {
        guard descriptor >= 0,!failed else { throw Failure.closed }
        do {
            guard rows < expectedRows else { throw Failure.invalidInput }
            try write(row)
            rows += 1
        } catch { failed=true;throw error }
    }
    @discardableResult func finish() throws -> Completion {
        guard descriptor >= 0,!failed else { throw Failure.closed }
        let prefixBytes=bytes
        do {
            guard rows==expectedRows else { throw Failure.invalidInput }
            struct Footer: Encodable {
                let type="footer",complete=true,nativeAcceptance=false,scored=false
                let rows:Int
            }
            try write(Footer(rows:rows))
            let receipt=try completion()
            let status=close(descriptor);descriptor = -1
            guard status==0 else { throw Failure.unavailable }
            return receipt
        } catch {
            // Best effort: a persistent IO error may prevent even rollback.
            // No successful receipt is returned in either case.
            if descriptor >= 0 {
                _=ftruncate(descriptor,off_t(prefixBytes))
                _=synchronize(descriptor)
            }
            failed=true;throw error
        }
    }
    private func completion() throws -> Completion {
        var first=stat(),last=stat(),named=stat()
        guard fstat(descriptor,&first)==0,first.st_size==bytes else { throw Failure.unavailable }
        var hash=SHA256(),offset=0
        var buffer=[UInt8](repeating:0,count:65_536)
        while offset < bytes {
            let count=buffer.withUnsafeMutableBytes { Darwin.pread(descriptor,$0.baseAddress,min($0.count,bytes-offset),off_t(offset)) }
            if count < 0 && errno==EINTR { continue }
            guard count > 0 else { throw Failure.unavailable }
            hash.update(data:Data(buffer.prefix(count)))
            offset += count
        }
        guard fstat(descriptor,&last)==0,lstat(url.path,&named)==0,
              first.st_dev==last.st_dev,first.st_ino==last.st_ino,last.st_size==bytes,
              last.st_dev==named.st_dev,last.st_ino==named.st_ino,
              first.st_mtimespec.tv_sec==last.st_mtimespec.tv_sec,
              first.st_mtimespec.tv_nsec==last.st_mtimespec.tv_nsec else { throw Failure.unavailable }
        return Completion(rows:rows,bytes:bytes,sha256:hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    private func write<T: Encodable>(_ value:T) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        var data=try encoder.encode(value)
        guard data.count<=65_536,bytes+data.count+1<=16_777_216 else { throw Failure.tooLarge }
        data.append(10)
        try data.withUnsafeBytes { buffer in
            var offset=0
            while offset < buffer.count {
                let count=Darwin.write(descriptor,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count < 0 && errno==EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        guard synchronize(descriptor)==0 else { throw Failure.unavailable }
        bytes += data.count
    }
}
