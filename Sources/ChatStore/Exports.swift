import ChatModel
import CoreServices
import Foundation

public enum ExportError: Error, Sendable, Equatable {
    /// Quarantine couldn't be set or verified, so no file was handed out.
    case quarantineFailed(code: Int)
    case io(code: Int)
    case media(MediaCacheError)
    /// Some entries couldn't be removed; `failed` is how many.
    case wipeIncomplete(failed: Int)
}

/// Plaintext copies of attachments for opening in other apps, under `exports/<accountID>/<uuid>/<filename>`.
/// Outside the crypto-shred guarantee, so every file is quarantined and the tree is wiped at logout and on launch.
///
/// Every directory below `root` is opened with `O_NOFOLLOW` and used by descriptor, so a symlink planted in the tree
/// can't redirect plaintext elsewhere.
public struct ExportDirectory: Sendable {
    public static let quarantineAttribute = "com.apple.quarantine"
    static let agentName = "gchat-mac"
    static let maxFilenameBytes = 255
    static let fallbackFilename = "attachment"

    /// Test seams; the defaults are the production behaviour.
    struct Seams: Sendable {
        var setQuarantineProperties: @Sendable (URL) throws -> Void = ExportDirectory.setQuarantineProperties
        var setQuarantineAttribute: @Sendable (Int32, String) -> Int32 = ExportDirectory.setQuarantineAttribute
        var isSandboxed: @Sendable () -> Bool = ExportDirectory.runningSandboxed
        var afterFolderCreated: @Sendable (URL) -> Void = { _ in }
        var beforeQuarantine: @Sendable (URL) -> Void = { _ in }
    }

    let directory: AccountDirectory
    let seams: Seams

    public init(directory: AccountDirectory) {
        self.init(directory: directory, seams: Seams())
    }

    init(directory: AccountDirectory, seams: Seams) {
        self.directory = directory
        self.seams = seams
    }

    /// Streams the verified plaintext of `reader` into a fresh quarantined file and returns its URL.
    public func export(from reader: MediaReader, filename: String) throws(ExportError) -> URL {
        let rootFD = try Self.openRoot(directory.root)
        defer { Darwin.close(rootFD) }
        let exportsFD = try Self.openDirectory(in: rootFD, name: "exports")
        defer { Darwin.close(exportsFD) }
        let accountFD = try Self.openDirectory(in: exportsFD, name: directory.account.description)
        defer { Darwin.close(accountFD) }

        let folderName = UUID().uuidString
        guard mkdirat(accountFD, folderName, 0o700) == 0 else { throw .io(code: Int(errno)) }
        let folderFD = openat(accountFD, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderFD >= 0 else {
            let code = Int(errno)
            unlinkat(accountFD, folderName, AT_REMOVEDIR)
            throw .io(code: code)
        }
        defer { Darwin.close(folderFD) }

        let name = Self.sanitize(filename)
        let folder = directory.exportsURL.appendingPathComponent(folderName, isDirectory: true)
        let url = folder.appendingPathComponent(name, isDirectory: false)
        do throws(ExportError) {
            guard fchmod(folderFD, 0o700) == 0 else { throw .io(code: Int(errno)) }
            seams.afterFolderCreated(folder)
            try write(reader, folderFD: folderFD, name: name, url: url)
        } catch {
            unlinkat(folderFD, name, 0)
            unlinkat(accountFD, folderName, AT_REMOVEDIR)
            throw error
        }
        return url
    }

    private func write(_ reader: MediaReader, folderFD: Int32, name: String, url: URL) throws(ExportError) {
        let fd = openat(folderFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .io(code: Int(errno)) }
        defer { Darwin.close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw .io(code: Int(errno)) }
        do throws(MediaCacheError) {
            while let chunk = try reader.next() { try writeAll(fd, chunk) }
        } catch {
            throw .media(error)
        }
        seams.beforeQuarantine(url)
        try quarantine(url, fd: fd)
    }

    private static func openRoot(_ root: URL) throws(ExportError) -> Int32 {
        var fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            try? FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard fd >= 0 else { throw .io(code: Int(errno)) }
        return fd
    }

    /// Opens `name` below `parent` without following a symlink, creating it (0700) if absent.
    private static func openDirectory(in parent: Int32, name: String) throws(ExportError) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(parent, name, flags)
        if fd < 0, errno == ENOENT {
            guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw .io(code: Int(errno)) }
            fd = openat(parent, name, flags)
        }
        guard fd >= 0 else { throw .io(code: Int(errno)) }
        guard fchmod(fd, 0o700) == 0 else {
            let code = Int(errno)
            Darwin.close(fd)
            throw .io(code: code)
        }
        return fd
    }

    /// Removes everything exported for this account. A symlink anywhere in the chain is unlinked itself and its
    /// target is left alone.
    public func wipe() throws(ExportError) {
        let rootFD = Darwin.open(directory.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            if errno == ENOENT { return }
            throw .io(code: Int(errno))
        }
        defer { Darwin.close(rootFD) }
        guard Self.isDirectory("exports", in: rootFD) else { return try Self.clear("exports", in: rootFD) }
        let exportsFD = openat(rootFD, "exports", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard exportsFD >= 0 else { throw .wipeIncomplete(failed: 1) }
        defer { Darwin.close(exportsFD) }
        try Self.clear(directory.account.description, in: exportsFD)
    }

    /// Removes the exports of every account, never following a symlink.
    public static func wipeAll(root: URL) throws(ExportError) {
        let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else {
            if errno == ENOENT { return }
            throw .io(code: Int(errno))
        }
        defer { Darwin.close(rootFD) }
        try clear("exports", in: rootFD)
    }

    // MARK: Quarantine

    /// Sandboxed apps may set quarantine only through resource values; the xattr is a fallback for unsandboxed runs.
    private func quarantine(_ url: URL, fd: Int32) throws(ExportError) {
        try Self.requireSameFile(url, fd: fd)
        do {
            try seams.setQuarantineProperties(url)
        } catch {
            guard !seams.isSandboxed() else { throw .quarantineFailed(code: (error as NSError).code) }
            try quarantineWithAttribute(fd)
            try Self.requireSameFile(url, fd: fd)
            return
        }
        try Self.requireSameFile(url, fd: fd)
        guard Self.hasQuarantineProperties(url) else { throw .quarantineFailed(code: Int(ENOATTR)) }
    }

    private func quarantineWithAttribute(_ fd: Int32) throws(ExportError) {
        let value = Self.quarantineValue()
        guard seams.setQuarantineAttribute(fd, value) == 0 else { throw .quarantineFailed(code: Int(errno)) }
        guard Self.quarantineAttribute(of: fd) == value else { throw .quarantineFailed(code: Int(ENOATTR)) }
    }

    /// The path must still name the file this descriptor wrote, not something swapped in since.
    private static func requireSameFile(_ url: URL, fd: Int32) throws(ExportError) {
        var opened = stat()
        var named = stat()
        guard fstat(fd, &opened) == 0 else { throw .io(code: Int(errno)) }
        guard lstat(url.path, &named) == 0, (named.st_mode & S_IFMT) == S_IFREG, named.st_dev == opened.st_dev,
            named.st_ino == opened.st_ino
        else { throw .io(code: Int(ESTALE)) }
    }

    static func setQuarantineProperties(_ url: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineAgentNameKey as String: agentName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
        ]
        var target = url
        try target.setResourceValues(values)
    }

    static func hasQuarantineProperties(_ url: URL) -> Bool {
        let fresh = URL(fileURLWithPath: url.path)
        guard let properties = (try? fresh.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        else { return false }
        return !properties.isEmpty
    }

    static func runningSandboxed() -> Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func quarantineValue(now: Date = Date()) -> String {
        let seconds = String(Int(now.timeIntervalSince1970), radix: 16)
        return "0083;\(seconds);\(agentName);\(UUID().uuidString)"
    }

    private static func setQuarantineAttribute(_ fd: Int32, _ value: String) -> Int32 {
        let bytes = Array(value.utf8)
        return fsetxattr(fd, quarantineAttribute, bytes, bytes.count, 0, 0)
    }

    private static func quarantineAttribute(of fd: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = fgetxattr(fd, quarantineAttribute, &buffer, buffer.count, 0, 0)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    // MARK: Filenames

    /// A single safe path component: no separators, control or bidi characters, no leading dots, at most 255 UTF-8
    /// bytes with a short extension preserved.
    public static func sanitize(_ filename: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: filename.unicodeScalars.filter { !isStripped($0) })
        let trimmed = String(scalars).drop { $0 == "." || $0.isWhitespace }
        var name = String(trimmed)
        while let last = name.last, last.isWhitespace { name.removeLast() }
        guard !name.isEmpty else { return fallbackFilename }
        guard name.utf8.count > maxFilenameBytes else { return name }

        var base = name
        var ext = ""
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            let candidate = String(name[dot...])
            if candidate.utf8.count <= 32 {
                ext = candidate
                base = String(name[..<dot])
            }
        }
        while !base.isEmpty, base.utf8.count + ext.utf8.count > maxFilenameBytes { base.removeLast() }
        while let last = base.last, last.isWhitespace || last == "." { base.removeLast() }
        return base.isEmpty ? fallbackFilename + ext : base + ext
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2F, 0x5C, 0x3A, 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: break
        }
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }

    // MARK: Wiping

    /// A real directory, not a symlink to one.
    private static func isDirectory(_ name: String, in parent: Int32) -> Bool {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// Removes `name` below `parent` (absent is fine) or reports how many of its entries could not be removed.
    private static func clear(_ name: String, in parent: Int32) throws(ExportError) {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw .io(code: Int(errno))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            guard unlinkat(parent, name, 0) == 0 || errno == ENOENT else { throw .wipeIncomplete(failed: 1) }
            return
        }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw .wipeIncomplete(failed: 1) }
        let failed = removeChildren(of: fd)
        Darwin.close(fd)
        guard failed == 0 else { throw .wipeIncomplete(failed: failed) }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw .wipeIncomplete(failed: 1) }
    }

    /// Returns how many direct children could not be removed. Symlinks are unlinked, never followed.
    private static func removeChildren(of directoryFD: Int32) -> Int {
        let duplicate = dup(directoryFD)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return 1
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.filter { !removeEntry($0, in: directoryFD) }.count
    }

    private static func removeEntry(_ name: String, in parent: Int32) -> Bool {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return unlinkat(parent, name, 0) == 0 || errno == ENOENT }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let failed = removeChildren(of: fd)
        Darwin.close(fd)
        return failed == 0 && (unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT)
    }
}
