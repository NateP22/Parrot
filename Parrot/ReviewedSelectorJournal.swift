import Foundation
import Darwin
import CryptoKit

/// Private component records. Consumers must match a returned completion receipt
/// to the file hash; a footer alone never proves successful execution/durability.
final class ReviewedSelectorJournal {
    enum Failure: Error { case invalidInput, unavailable, closed, tooLarge }
    struct Completion: Encodable { let rows:Int; let bytes:Int; let sha256:String }
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
