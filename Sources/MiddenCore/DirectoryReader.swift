import Foundation

/// One entry of a directory listing, with the metadata the scanner needs.
struct DirectoryEntry: Sendable, Hashable {
    enum Kind: UInt8, Sendable {
        case file, directory, symlink, other
    }

    var name: String
    var kind: Kind
    /// Device the entry lives on. A subdirectory on another device is a mount point.
    var device: Int32
    var inode: UInt64
    /// Number of hard links. Always 1 for directories (not requested for them).
    var linkCount: UInt32
    /// Bytes allocated on disk, all forks included: what `du` counts.
    /// For a sparse file this is far less than its length.
    var allocatedSize: Int64
    /// Modification time, seconds since 1970.
    var modified: Double
}

/// What a directory listing returned, and whether that is all of it.
struct DirectoryListing: Sendable {
    /// Entries read with all their metadata. Each appears once.
    var entries: [DirectoryEntry]
    /// Why some entries are missing (an entry the file system couldn't
    /// describe, or a read that failed partway). Nil when complete.
    var error: POSIXError?

    var isComplete: Bool { error == nil }
}

/// Reads a directory with getattrlistbulk(2): one system call returns a batch
/// of entries with their names, types, inode numbers, link counts, sizes and
/// dates, instead of readdir(3) plus one lstat(2) per entry.
///
/// A listing is never presented as complete when it isn't: an entry with an
/// error or without one of the attributes below is left out and marks the
/// listing incomplete, and so does a read that fails after some batches,
/// whose earlier entries are kept.
///
/// Not thread-safe: it reuses one buffer. Give each thread its own reader.
final class DirectoryReader {
    /// The system calls the reader makes, replaceable in tests to inject
    /// failures. Each returns errno as it was right after the call.
    struct Calls {
        var bulk: (_ fd: Int32, _ request: UnsafeMutablePointer<attrlist>, _ buffer: UnsafeMutableRawBufferPointer)
            -> (count: Int32, errno: Int32)
        /// Next readdir(3) entry's name, nil at the end (errno 0) or on an error.
        var readdir: (_ dir: UnsafeMutablePointer<DIR>) -> (name: String?, errno: Int32)
        var fstatat: (_ fd: Int32, _ name: String, _ info: inout stat) -> Int32

        static var system: Calls { Calls(
            bulk: { fd, request, buffer in
                let count = getattrlistbulk(fd, request, buffer.baseAddress!, buffer.count, 0)
                return (count, count < 0 ? errno : 0)
            },
            readdir: { dir in
                errno = 0
                guard let raw = Darwin.readdir(dir) else { return (nil, errno) }
                let name = withUnsafeBytes(of: raw.pointee.d_name) { bytes in
                    String(decoding: bytes.prefix(Int(raw.pointee.d_namlen)), as: UTF8.self)
                }
                return (name, 0)
            },
            fstatat: { fd, name, info in
                Darwin.fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 ? 0 : errno
            }) }
    }

    private let buffer: UnsafeMutableRawBufferPointer
    var calls = Calls.system
    /// getattrlistbulk calls made so far; lets tests check batching.
    private(set) var bulkCalls = 0
    /// Called after every batch, so a watchdog can tell a big folder that is
    /// still being read from a call that is stuck.
    var onBatch: (() -> Void)?

    /// Interrupted calls are retried this many times in a row before the
    /// listing gives up; out-of-memory errors, with a short pause, fewer.
    static let interruptRetries = 100
    static let memoryRetries = 3
    /// The readdir fallback reports progress every this many entries.
    static let fallbackBatch = 256

    /// Attributes every entry must come with. Folders also need their
    /// allocated size; everything else (files, symlinks, devices) its link
    /// count and allocated size, which getattrlistbulk returns for all of
    /// them on APFS and devfs.
    private static let requiredCommon = attrgroup_t(
        ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
    private static let requiredDirectory = attrgroup_t(ATTR_DIR_ALLOCSIZE)
    private static let requiredOther = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)

    /// - Parameter bufferSize: bytes per getattrlistbulk call. One record is
    ///   about 80 bytes plus the name, so the default fits ~1,500 entries.
    init(bufferSize: Int = 128 * 1024) {
        buffer = .allocate(byteCount: bufferSize, alignment: 8)
    }

    deinit {
        buffer.deallocate()
    }

    /// Every entry of `path`, or an error: an incomplete listing throws.
    /// Never follows a symlink at `path` itself.
    func entries(atPath path: String) throws(POSIXError) -> [DirectoryEntry] {
        let listing = try listing(atPath: path)
        if let error = listing.error { throw error }
        return listing.entries
    }

    /// Every entry of an open directory, or an error. The caller keeps `fd`.
    func entries(directory fd: Int32) throws(POSIXError) -> [DirectoryEntry] {
        let listing = try listing(directory: fd)
        if let error = listing.error { throw error }
        return listing.entries
    }

    /// Lists `path` without following a symlink at `path` itself. Throws
    /// when it can't be opened or nothing at all could be read.
    func listing(atPath path: String) throws(POSIXError) -> DirectoryListing {
        var fd: Int32
        repeat {
            fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        } while fd < 0 && errno == EINTR
        if fd < 0 { throw POSIXError(errno) }
        defer { close(fd) }
        return try listing(directory: fd)
    }

    /// Lists an open directory. The caller keeps ownership of `fd`.
    func listing(directory fd: Int32) throws(POSIXError) -> DirectoryListing {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(
                ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE
                    | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_ALLOCSIZE)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)

        var listing = DirectoryListing(entries: [], error: nil)
        var firstCall = true
        var interrupted = 0
        var outOfMemory = 0
        while true {
            let (count, code) = calls.bulk(fd, &request, buffer)
            bulkCalls += 1
            // errno was captured above, so the callback can't change it.
            onBatch?()
            if count < 0 {
                if code == EINTR, interrupted < Self.interruptRetries {
                    interrupted += 1
                    continue
                }
                if code == ENOMEM, outOfMemory < Self.memoryRetries {
                    outOfMemory += 1
                    usleep(useconds_t(1_000 * outOfMemory))
                    continue
                }
                // Some file systems don't support it at all; they fail at once.
                if code == ENOTSUP, firstCall {
                    return try readdirListing(directory: fd)
                }
                // Nothing read: the listing failed. Otherwise keep what was read.
                if firstCall { throw POSIXError(code) }
                listing.error = POSIXError(code)
                return listing
            }
            firstCall = false
            interrupted = 0
            outOfMemory = 0
            if count == 0 { return listing }
            if !parse(batch: Int(count), into: &listing) { return listing }
        }
    }

    /// Parses one batch of records into `listing`. Returns false when a
    /// record is malformed: the rest of the batch can't be trusted, so the
    /// listing stops there, incomplete.
    private func parse(batch count: Int, into listing: inout DirectoryListing) -> Bool {
        let base = UnsafeRawPointer(buffer.baseAddress!)
        let header = MemoryLayout<UInt32>.size + MemoryLayout<attribute_set_t>.size
        var offset = 0
        for _ in 0..<count {
            guard offset + header <= buffer.count else {
                listing.error = listing.error ?? POSIXError(.EIO)
                return false
            }
            let length = Int(base.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length >= header, offset + length <= buffer.count else {
                listing.error = listing.error ?? POSIXError(.EIO)
                return false
            }
            let record = UnsafeRawBufferPointer(start: base + offset, count: length)
            switch Self.parse(record: record) {
            case .success(let entry):
                listing.entries.append(entry)
            case .failure(let error):
                listing.error = listing.error ?? error
            }
            offset += length
        }
        return true
    }

    /// Parses one record. Attributes appear in the order of their bits in
    /// <sys/attr.h> (common, then directory, then file attributes), each
    /// 4-byte aligned, and only those named in the returned attribute set.
    /// ATTR_CMN_ERROR is the exception: it comes right after the returned set.
    /// An entry with an error, a required attribute missing, or a field
    /// outside its record fails.
    static func parse(record: UnsafeRawBufferPointer) -> Result<DirectoryEntry, POSIXError> {
        let start = record.baseAddress!
        let end = record.count
        var offset = MemoryLayout<UInt32>.size
        func has(_ size: Int) -> Bool { offset + size <= end }
        guard has(MemoryLayout<attribute_set_t>.size) else { return .failure(POSIXError(.EIO)) }
        let returned = start.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
        offset += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            guard has(4) else { return .failure(POSIXError(.EIO)) }
            let error = start.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            offset += 4
            if error != 0 { return .failure(POSIXError(Int32(error))) }
        }
        guard common & requiredCommon == requiredCommon else {
            return .failure(POSIXError(.ENOATTR))
        }

        guard has(MemoryLayout<attrreference_t>.size) else { return .failure(POSIXError(.EIO)) }
        let nameRef = start.loadUnaligned(fromByteOffset: offset, as: attrreference_t.self)
        // The name's offset is from the reference itself; its length counts
        // the terminating NUL.
        let nameStart = offset + Int(nameRef.attr_dataoffset)
        let nameLength = Int(nameRef.attr_length) - 1
        guard nameRef.attr_dataoffset > 0, nameLength >= 0, nameStart + nameLength <= end else {
            return .failure(POSIXError(.EIO))
        }
        let name = String(
            decoding: UnsafeRawBufferPointer(start: start + nameStart, count: nameLength), as: UTF8.self)
        offset += MemoryLayout<attrreference_t>.size

        guard has(4 + 4 + MemoryLayout<timespec>.size + 8) else { return .failure(POSIXError(.EIO)) }
        let device = start.loadUnaligned(fromByteOffset: offset, as: Int32.self)
        offset += 4
        let kind = Self.kind(vnodeType: start.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        offset += 4
        let time = start.loadUnaligned(fromByteOffset: offset, as: timespec.self)
        offset += MemoryLayout<timespec>.size
        let inode = start.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
        offset += 8

        var entry = DirectoryEntry(
            name: name, kind: kind, device: device, inode: inode, linkCount: 1, allocatedSize: 0,
            modified: Double(time.tv_sec) + Double(time.tv_nsec) / 1e9)
        if kind == .directory {
            guard returned.dirattr & requiredDirectory == requiredDirectory else {
                return .failure(POSIXError(.ENOATTR))
            }
            guard has(8) else { return .failure(POSIXError(.EIO)) }
            entry.allocatedSize = start.loadUnaligned(fromByteOffset: offset, as: Int64.self)
        } else {
            guard returned.fileattr & requiredOther == requiredOther else {
                return .failure(POSIXError(.ENOATTR))
            }
            guard has(4 + 8) else { return .failure(POSIXError(.EIO)) }
            entry.linkCount = start.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            entry.allocatedSize = start.loadUnaligned(fromByteOffset: offset + 4, as: Int64.self)
        }
        return .success(entry)
    }

    private static func kind(vnodeType: UInt32) -> DirectoryEntry.Kind {
        switch vnodeType {
        case VREG.rawValue: .file
        case VDIR.rawValue: .directory
        case VLNK.rawValue: .symlink
        default: .other
        }
    }

    private static func kind(mode: mode_t) -> DirectoryEntry.Kind {
        switch mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
    }

    /// Every entry via readdir(3) plus fstatat(2), or an error. The reference
    /// the tests compare getattrlistbulk with.
    static func readdirEntries(directory fd: Int32) throws(POSIXError) -> [DirectoryEntry] {
        let listing = try DirectoryReader(bufferSize: 64).readdirListing(directory: fd)
        if let error = listing.error { throw error }
        return listing.entries
    }

    /// Fallback for file systems without getattrlistbulk support:
    /// readdir(3) plus one fstatat(2) per entry, never following symlinks.
    /// An entry that vanished between the two calls is left out; any other
    /// failure, including one that ends readdir early, makes the listing
    /// incomplete.
    func readdirListing(directory fd: Int32) throws(POSIXError) -> DirectoryListing {
        let copy = dup(fd)
        if copy < 0 { throw POSIXError(errno) }
        guard let dir = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw POSIXError(code)
        }
        defer { closedir(dir) }
        var listing = DirectoryListing(entries: [], error: nil)
        var seen = 0
        while true {
            let (next, code) = calls.readdir(dir)
            guard let name = next else {
                if code != 0 { listing.error = POSIXError(code) }
                break
            }
            seen += 1
            if seen % Self.fallbackBatch == 0 { onBatch?() }
            if name == "." || name == ".." { continue }
            var info = stat()
            var failure: Int32
            var attempts = 0
            repeat {
                failure = calls.fstatat(fd, name, &info)
                attempts += 1
            } while failure == EINTR && attempts < Self.interruptRetries
            if failure == ENOENT { continue }
            if failure != 0 {
                listing.error = listing.error ?? POSIXError(failure)
                continue
            }
            let kind = Self.kind(mode: info.st_mode)
            listing.entries.append(DirectoryEntry(
                name: name,
                kind: kind,
                device: info.st_dev,
                inode: info.st_ino,
                linkCount: kind == .directory ? 1 : UInt32(info.st_nlink),
                allocatedSize: Int64(info.st_blocks) * 512,
                modified: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1e9))
        }
        onBatch?()
        return listing
    }
}

extension POSIXError {
    init(_ code: Int32) {
        self.init(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
