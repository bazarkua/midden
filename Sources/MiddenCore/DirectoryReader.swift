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

/// Reads a directory with getattrlistbulk(2): one system call returns a batch
/// of entries with their names, types, inode numbers, link counts, sizes and
/// dates, instead of readdir(3) plus one lstat(2) per entry.
///
/// Not thread-safe: it reuses one buffer. Give each thread its own reader.
final class DirectoryReader {
    private let buffer: UnsafeMutableRawBufferPointer
    /// getattrlistbulk calls made so far; lets tests check batching.
    private(set) var bulkCalls = 0
    /// Called after every batch, so a watchdog can tell a big folder that is
    /// still being read from a call that is stuck.
    var onBatch: (() -> Void)?

    /// - Parameter bufferSize: bytes per getattrlistbulk call. One record is
    ///   about 80 bytes plus the name, so the default fits ~1,500 entries.
    init(bufferSize: Int = 128 * 1024) {
        buffer = .allocate(byteCount: bufferSize, alignment: 8)
    }

    deinit {
        buffer.deallocate()
    }

    /// Lists `path` without following a symlink at `path` itself.
    func entries(atPath path: String) throws(POSIXError) -> [DirectoryEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { throw POSIXError(errno) }
        defer { close(fd) }
        return try entries(directory: fd)
    }

    /// Lists an open directory. The caller keeps ownership of `fd`.
    func entries(directory fd: Int32) throws(POSIXError) -> [DirectoryEntry] {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(
                ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID | ATTR_CMN_OBJTYPE
                    | ATTR_CMN_MODTIME | ATTR_CMN_FILEID)
        request.dirattr = attrgroup_t(ATTR_DIR_ALLOCSIZE)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE)

        var result: [DirectoryEntry] = []
        var firstCall = true
        while true {
            let count = getattrlistbulk(fd, &request, buffer.baseAddress!, buffer.count, 0)
            bulkCalls += 1
            onBatch?()
            if count < 0 {
                let code = errno
                // Some file systems don't support it at all; they fail at once.
                if code == ENOTSUP, firstCall {
                    return try Self.readdirEntries(directory: fd)
                }
                throw POSIXError(code)
            }
            firstCall = false
            if count == 0 { return result }
            var record = UnsafeRawPointer(buffer.baseAddress!)
            for _ in 0..<count {
                let length = record.loadUnaligned(as: UInt32.self)
                if let entry = Self.parse(record: record) {
                    result.append(entry)
                }
                record += Int(length)
            }
        }
    }

    /// Parses one record. Attributes appear in the order of their bits in
    /// <sys/attr.h> (common, then directory, then file attributes), each
    /// 4-byte aligned, and only those named in the returned attribute set.
    /// ATTR_CMN_ERROR is the exception: it comes right after the returned set.
    private static func parse(record: UnsafeRawPointer) -> DirectoryEntry? {
        var field = record + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            let error = field.loadUnaligned(as: UInt32.self)
            field += 4
            if error != 0 { return nil }
        }
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0 else { return nil }
        let nameRef = field.loadUnaligned(as: attrreference_t.self)
        // attr_length counts the terminating NUL.
        let nameBytes = UnsafeRawBufferPointer(
            start: field + Int(nameRef.attr_dataoffset),
            count: max(Int(nameRef.attr_length) - 1, 0))
        let name = String(decoding: nameBytes, as: UTF8.self)
        field += MemoryLayout<attrreference_t>.size

        var entry = DirectoryEntry(
            name: name, kind: .other, device: 0, inode: 0, linkCount: 1,
            allocatedSize: 0, modified: 0)
        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            entry.device = field.loadUnaligned(as: Int32.self)
            field += 4
        }
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            entry.kind = Self.kind(vnodeType: field.loadUnaligned(as: UInt32.self))
            field += 4
        }
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            let time = field.loadUnaligned(as: timespec.self)
            entry.modified = Double(time.tv_sec) + Double(time.tv_nsec) / 1e9
            field += MemoryLayout<timespec>.size
        }
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            entry.inode = field.loadUnaligned(as: UInt64.self)
            field += 8
        }
        if returned.dirattr & attrgroup_t(ATTR_DIR_ALLOCSIZE) != 0 {
            entry.allocatedSize = field.loadUnaligned(as: Int64.self)
            field += 8
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            entry.linkCount = field.loadUnaligned(as: UInt32.self)
            field += 4
        }
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            entry.allocatedSize = field.loadUnaligned(as: Int64.self)
            field += 8
        }
        return entry
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

    /// Fallback for file systems without getattrlistbulk support:
    /// readdir(3) plus one fstatat(2) per entry, never following symlinks.
    static func readdirEntries(directory fd: Int32) throws(POSIXError) -> [DirectoryEntry] {
        let copy = dup(fd)
        if copy < 0 { throw POSIXError(errno) }
        guard let dir = fdopendir(copy) else {
            let code = errno
            close(copy)
            throw POSIXError(code)
        }
        defer { closedir(dir) }
        var result: [DirectoryEntry] = []
        while let raw = readdir(dir) {
            let name = withUnsafeBytes(of: raw.pointee.d_name) { bytes in
                let length = Int(raw.pointee.d_namlen)
                return String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = kind(mode: info.st_mode)
            result.append(DirectoryEntry(
                name: name,
                kind: kind,
                device: info.st_dev,
                inode: info.st_ino,
                linkCount: kind == .directory ? 1 : UInt32(info.st_nlink),
                allocatedSize: Int64(info.st_blocks) * 512,
                modified: Double(info.st_mtimespec.tv_sec)
                    + Double(info.st_mtimespec.tv_nsec) / 1e9))
        }
        return result
    }
}

extension POSIXError {
    init(_ code: Int32) {
        self.init(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
}
