import ChatModel
import CoreServices
import Foundation
import Synchronization

public enum ExportError: Error, Sendable, Equatable {
    /// Quarantine couldn't be set or verified, so no file was handed out.
    case quarantineFailed(code: Int)
    case io(code: Int)
    case media(MediaCacheError)
    /// Some entries couldn't be removed; `failed` is how many.
    case wipeIncomplete(failed: Int)
    /// The caller withdrew (its session ended) before a copy was handed out; nothing new was left behind.
    case withdrawn
}

/// Plaintext copies of attachments for opening in other apps, under `exports/<accountID>/<folder>/<filename>`. The
/// folder is the attachment's keyed cache name, so it keeps one copy that later exports hand back, or a UUID for a
/// throwaway copy. Outside the crypto-shred guarantee, so every file is quarantined, copies are removed once they
/// haven't been changed or handed out for `maxAge` (checked at launch and whenever a new copy is made), and the
/// account's tree is wiped at logout.
///
/// Every directory below `root` is opened with `O_NOFOLLOW` and used by descriptor, so a symlink planted in the tree
/// can't redirect plaintext elsewhere.
public struct ExportDirectory: Sendable {
    public static let quarantineAttribute = "com.apple.quarantine"
    /// Long enough for the app a copy was opened in to read it, short enough that decrypted copies don't pile up
    /// while the app stays open.
    public static let maxAge: TimeInterval = 24 * 60 * 60
    static let agentName = "Thimble"
    static let maxFilenameBytes = 255
    static let fallbackFilename = "attachment"

    /// Every step that creates, hands out or removes copies runs through `locked`: an export claiming its folder and
    /// publishing its file, pruning's decision and removal of each entry, and a wipe. Writing a copy's contents
    /// happens outside it: a temporary being written is told apart from an abandoned one by its own file lock, which
    /// conflicts within this process just as it does between processes.
    ///
    /// Within this process the steps at one root take turns in the order they asked, so a long sweep, which asks
    /// again for each entry, lets an export or a wipe that is waiting in before its next entry. Roots don't wait for
    /// each other. A root is its path, so steps keep taking turns even if the directory there is replaced.
    private static let turns = TurnLines()

    /// The file other processes using the same container, such as a second copy of the app, take turns through. It
    /// sits beside `exports`, so no wipe or prune removes it.
    static let lockName = ".exports.lock"

    /// How long a step waits for its turn and for another process to let go of the shared lock before giving up, so
    /// neither a stalled step here nor a stalled second copy of the app can hold up logout.
    static let lockWait: Duration = .seconds(5)

    /// The pause between two tries at a shared lock another process holds.
    static let lockRetry: Duration = .milliseconds(10)

    private static let clockStart = ContinuousClock.now

    static func monotonicNow() -> Duration { ContinuousClock.now - clockStart }

    /// One step's place in a root's line. Granted at most once.
    final class LockTurn: Sendable {
        private let granted = DispatchSemaphore(value: 0)
        /// When the step gives up, on the clock its `Seams.now` reads. A turn nobody queues has none.
        fileprivate let deadline: Duration

        init(deadline: Duration = .zero) { self.deadline = deadline }

        fileprivate func grant() { granted.signal() }

        /// Returns once the turn is granted or `limit` has passed, whichever comes first.
        func wait(upTo limit: Duration) {
            let nanoseconds = Int(min(max(limit / .nanoseconds(1), 0), 1e18))
            _ = granted.wait(timeout: .now() + .nanoseconds(nanoseconds))
        }
    }

    /// The turns of this process's steps, one line per export root. A root has an entry only while a step holds its
    /// slot.
    private final class TurnLines: Sendable {
        private struct Line {
            var holder: LockTurn
            /// False while the holder was handed the slot and its thread hasn't come back for it yet.
            var taken: Bool
            var waiting: [LockTurn] = []

            /// Hands the slot to the first in line that hasn't given up by `now`, when there is one. `woken` gets
            /// that step and the ones passed over, which wake to find their wait has run out.
            mutating func handOn(_ now: Duration, waking woken: inout [LockTurn]) -> Bool {
                woken += waiting.filter { $0.deadline <= now }
                waiting.removeAll { $0.deadline <= now }
                guard !waiting.isEmpty else { return false }
                holder = waiting.removeFirst()
                taken = false
                woken.append(holder)
                return true
            }
        }

        private let lines = Mutex<[String: Line]>([:])

        /// True when `turn` holds the root's slot: it was free, or the turn was handed it. Otherwise the turn is in
        /// line, joining at the end if it wasn't already. A slot handed to a step that gave up before coming back for
        /// it moves on, so a stalled thread can't keep the root reserved.
        func take(_ turn: LockTurn, at root: String, now: Duration) -> Bool {
            var woken: [LockTurn] = []
            let holds = lines.withLock { lines -> Bool in
                guard var line = lines[root] else {
                    lines[root] = Line(holder: turn, taken: true)
                    return true
                }
                defer { lines[root] = line }
                if line.holder === turn {
                    line.taken = true
                    return true
                }
                if !line.waiting.contains(where: { $0 === turn }) { line.waiting.append(turn) }
                guard !line.taken, line.holder.deadline <= now else { return false }
                if !line.handOn(now, waking: &woken) {
                    // Everyone in line has given up, this step included; it takes the slot and finds that out.
                    line.holder = turn
                }
                line.taken = line.holder === turn
                return line.taken
            }
            for other in woken where other !== turn { other.grant() }
            return holds
        }

        /// Gives the turn up. Holding the slot, it hands it to the first in line; waiting, it leaves the line.
        func leave(_ turn: LockTurn, at root: String, now: Duration) {
            var woken: [LockTurn] = []
            lines.withLock { lines in
                guard var line = lines[root] else { return }
                guard line.holder === turn else {
                    line.waiting.removeAll { $0 === turn }
                    lines[root] = line
                    return
                }
                lines[root] = line.handOn(now, waking: &woken) ? line : nil
            }
            for other in woken { other.grant() }
        }
    }

    /// Runs `body` holding the slot of `root`, which must exist, in this process and, against other processes, an
    /// exclusive lock on `lockName` under it. Without both nothing runs: a file at `lockName` that can't be opened
    /// as one (a symlink, say) throws, and so does `seams.lockWait` running out, which bounds the whole call,
    /// whether it is waiting in line here or for another process: once it has run out, `body` doesn't start even if
    /// both are free. The shared lock is never waited on while holding the slot: it is tried, and when another
    /// process has it the slot goes to the next in line before the pause and this step rejoins at the end.
    private static func locked<T>(
        _ root: URL, seams: Seams, site: LockSite, _ body: () throws(ExportError) -> T
    ) throws(ExportError) -> T {
        let deadline = seams.now() + seams.lockWait
        let line = root.standardizedFileURL.path
        let path = root.appendingPathComponent(lockName).path
        while true {
            let turn = LockTurn(deadline: deadline)
            var queued = false
            while !turns.take(turn, at: line, now: seams.now()) {
                if !queued {
                    queued = true
                    seams.onLockBusy(site)
                }
                let left = deadline - seams.now()
                guard left > .zero else {
                    // Handed the slot at this very moment, it goes on to the next in line.
                    turns.leave(turn, at: line, now: seams.now())
                    throw .io(code: Int(ETIMEDOUT))
                }
                seams.wait(turn, left)
            }
            let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
            guard fd >= 0 else {
                let code = errno
                turns.leave(turn, at: line, now: seams.now())
                guard code == EWOULDBLOCK else { throw .io(code: Int(code)) }
                seams.onLockBusy(site)
                let left = deadline - seams.now()
                guard left > .zero else { throw .io(code: Int(ETIMEDOUT)) }
                seams.wait(LockTurn(), min(left, lockRetry))
                continue
            }
            defer {
                // The shared lock goes first, so whoever is handed the slot finds it free.
                Darwin.close(fd)
                turns.leave(turn, at: line, now: seams.now())
            }
            // A turn can come after the wait ran out; it holds both, but nothing starts.
            guard seams.now() < deadline else { throw .io(code: Int(ETIMEDOUT)) }
            seams.onLockAdmitted(site)
            return try body()
        }
    }

    /// Whether `root` is there, without creating it: pruning and wiping have nothing to do when it isn't. Only "no
    /// such file" means it isn't; any other failure to look throws, so a wipe that can't look is reported, not
    /// skipped.
    private static func rootExists(_ root: URL) throws(ExportError) -> Bool {
        var info = stat()
        guard stat(root.path, &info) == 0 else {
            let code = errno
            if code == ENOENT { return false }
            throw .io(code: Int(code))
        }
        return true
    }

    /// The step a `locked` call is for.
    enum LockSite: Sendable, Equatable {
        case claim, publish, cleanup, wipe, prune
    }

    /// Test seams; the defaults are the production behaviour.
    struct Seams: Sendable {
        var setQuarantineProperties: @Sendable (URL) throws -> Void = ExportDirectory.setQuarantineProperties
        var setQuarantineAttribute: @Sendable (Int32, String) -> Int32 = ExportDirectory.setQuarantineAttribute
        var isSandboxed: @Sendable () -> Bool = ExportDirectory.runningSandboxed
        var afterFolderCreated: @Sendable (URL) -> Void = { _ in }
        var beforeQuarantine: @Sendable (URL) -> Void = { _ in }
        /// Runs while pruning holds the lock, after deciding an entry is old and before removing it.
        var beforePruneRemoval: @Sendable (String) -> Void = { _ in }
        /// Runs after a stored copy is opened and checked, before its path is matched against it and it's handed out.
        var beforeHandingOutStored: @Sendable (URL) -> Void = { _ in }
        var lockWait: Duration = ExportDirectory.lockWait
        /// Monotonic time, as the time since a fixed moment; `lockWait` is counted on it.
        var now: @Sendable () -> Duration = ExportDirectory.monotonicNow
        /// Blocks until the turn is granted or the time given has passed. Every wait for the lock goes through it:
        /// for a turn in line, and, with a turn nobody grants, the pause before trying the shared lock again.
        var wait: @Sendable (LockTurn, Duration) -> Void = { $0.wait(upTo: $1) }
        /// Runs each time a step finds the lock busy: once it has joined its root's line, and at each try that finds
        /// another process holding the shared lock.
        var onLockBusy: @Sendable (LockSite) -> Void = { _ in }
        /// Runs holding the lock, right before the step's work starts, so calls come in the order turns are taken.
        var onLockAdmitted: @Sendable (LockSite) -> Void = { _ in }
        /// Runs as pruning is about to take the lock for an entry.
        var onPruneEntryAttempt: @Sendable (String) -> Void = { _ in }
        /// Marks a stored copy's folder as just used; returns 0, or the error code.
        var markUsed: @Sendable (Int32) -> Int32 = { futimens($0, nil) == 0 ? 0 : errno }
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

    /// Where `export` puts a copy.
    public enum Placement: Sendable {
        /// The attachment's own folder: an export finds the copy already stored there and hands it back rather
        /// than writing another.
        case shared
        /// A new folder for this copy alone, for a caller that deletes it as soon as it's done with it.
        case unique
    }

    /// Where `export` is when it asks whether it may still hand out a copy.
    public enum Stage: Sendable, Equatable {
        /// Before anything is created.
        case starting
        /// Under the lock, before any folder is created or opened.
        case claiming
        /// Under the lock, once a new copy is written, before anything else is touched.
        case publishing
        /// Under the lock, right before a copy, stored or new, is handed out.
        case handingOut
    }

    /// Returns a quarantined plaintext copy of `reader`'s media, named after `filename`. With `.shared`, the copy
    /// already stored under that name in the attachment's folder is handed back as it is (the app it was opened in
    /// may have changed it), marked as just used, with its quarantine restored if macOS can't read it. Otherwise
    /// the verified plaintext is written under a temporary name and moved into place, never over anything. An
    /// export never replaces or removes anything it didn't write. `shouldHandOut` is asked at each `Stage`; when it
    /// says no, the export leaves nothing new behind and throws `.withdrawn`.
    public func export(
        from reader: MediaReader, filename: String, placement: Placement = .shared,
        shouldHandOut: (Stage) -> Bool = { _ in true }
    ) throws(ExportError) -> URL {
        // A session that has already ended gets nothing.
        guard shouldHandOut(.starting) else { throw .withdrawn }
        let folderName = placement == .shared ? reader.hash : UUID().uuidString
        let folder = directory.exportsURL.appendingPathComponent(folderName, isDirectory: true)
        let name = Self.sanitize(filename)
        // Sanitized names never start with a dot, so this can't collide with a copy.
        let temporary = ".\(UUID().uuidString).partial"
        // The shared lock lives in the root, so even the very first export takes it before creating anything below.
        Darwin.close(try Self.openRoot(directory.root))
        let claimed = try Self.locked(directory.root, seams: seams, site: .claim) {
            () throws(ExportError) -> Claim in
            // Asked again under the lock, which logout's wipe holds: a session that ended meanwhile creates
            // nothing, not even the account's folder.
            guard shouldHandOut(.claiming) else { throw .withdrawn }
            let rootFD = try Self.openRoot(directory.root)
            defer { Darwin.close(rootFD) }
            let exportsFD = try Self.openDirectory(in: rootFD, name: "exports")
            defer { Darwin.close(exportsFD) }
            let accountFD = try Self.openDirectory(in: exportsFD, name: directory.account.description)
            do throws(ExportError) {
                let claimed = try claim(
                    folderName, in: accountFD, placement: placement, name: name, temporary: temporary,
                    folder: folder, shouldHandOut: shouldHandOut)
                if case .stored = claimed { Darwin.close(accountFD) }
                return claimed
            } catch {
                Darwin.close(accountFD)
                throw error
            }
        }
        let accountFD: Int32
        let folderFD: Int32
        let fd: Int32
        switch claimed {
        case .stored(let stored):
            return stored
        case .writing(let openAccount, let openFolder, let file):
            (accountFD, folderFD, fd) = (openAccount, openFolder, file)
        }
        defer {
            // Closing the temporary file also lets go of its lock.
            Darwin.close(fd)
            Darwin.close(folderFD)
            Darwin.close(accountFD)
        }
        do throws(ExportError) {
            seams.afterFolderCreated(folder)
            do throws(MediaCacheError) {
                while let chunk = try reader.next() { try writeAll(fd, chunk) }
            } catch {
                throw .media(error)
            }
            let staged = folder.appendingPathComponent(temporary, isDirectory: false)
            seams.beforeQuarantine(staged)
            try quarantine(staged, fd: fd)
            return try Self.locked(directory.root, seams: seams, site: .publish) {
                () throws(ExportError) -> URL in
                try publish(fd, from: temporary, as: name, in: folderFD, folder: folder, shouldHandOut: shouldHandOut)
            }
        } catch {
            // Without the lock nothing is removed here: the temporary is left for a later cleanup, which takes it
            // once this export closes it and so lets go of its file lock.
            try? Self.locked(directory.root, seams: seams, site: .cleanup) {
                () throws(ExportError) in
                // Only what this export made goes: its temporary file, and the folder if that leaves it empty.
                // Whatever is at the copy's name, even something planted there, is left for the wipe.
                unlinkat(folderFD, temporary, 0)
                unlinkat(accountFD, folderName, AT_REMOVEDIR)
            }
            throw error
        }
    }

    private enum Claim {
        /// The copy stored earlier under the attachment's name, ready to hand back.
        case stored(URL)
        /// A new copy to write: the open account and copy folders, and the temporary file it goes into.
        case writing(account: Int32, folder: Int32, file: Int32)
    }

    /// Opens (creating if needed) the copy's folder and clears out temporaries nobody is writing. The copy already
    /// stored under `name` is marked as just used and handed back; otherwise this export's temporary file is
    /// created holding its file lock, which keeps every cleanup, in this process or another, off it. Called with
    /// the lock held, so when it returns the folder was changed just now and holds the copy or a file this export
    /// owns: neither pruning nor another export's cleanup removes it.
    private func claim(
        _ folderName: String, in accountFD: Int32, placement: Placement, name: String, temporary: String,
        folder: URL, shouldHandOut: (Stage) -> Bool
    ) throws(ExportError) -> Claim {
        let created = mkdirat(accountFD, folderName, 0o700) == 0
        guard created || (placement == .shared && errno == EEXIST) else { throw .io(code: Int(errno)) }
        let folderFD = openat(accountFD, folderName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard folderFD >= 0 else {
            let code = Int(errno)
            if created { unlinkat(accountFD, folderName, AT_REMOVEDIR) }
            throw .io(code: code)
        }
        func giveUp(_ error: ExportError) -> ExportError {
            Darwin.close(folderFD)
            // Only succeeds once the folder is empty, so it never takes a copy, or anything else, with it.
            unlinkat(accountFD, folderName, AT_REMOVEDIR)
            return error
        }
        guard fchmod(folderFD, 0o700) == 0 else { throw giveUp(.io(code: Int(errno))) }
        Self.reapAbandoned(in: folderFD)
        do throws(ExportError) {
            if let stored = try storedCopy(name, in: folderFD, folder: folder, shouldHandOut: shouldHandOut) {
                // Marked as just used, so pruning keeps it for another `maxAge`. One that can't be marked isn't
                // handed out: the sweep that follows an export could take it before the app opening it reads it.
                let code = seams.markUsed(folderFD)
                guard code == 0 else { throw .io(code: Int(code)) }
                Darwin.close(folderFD)
                return .stored(stored)
            }
        } catch {
            throw giveUp(error)
        }
        // Created already locked, under the lock every cleanup holds, and kept locked until the export closes it, so
        // a cleanup here or in another process can tell it's being written from the moment it exists.
        let fd = openat(
            folderFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        guard fd >= 0, fchmod(fd, 0o600) == 0 else {
            let code = Int(errno)
            if fd >= 0 {
                Darwin.close(fd)
                unlinkat(folderFD, temporary, 0)
            }
            throw giveUp(.io(code: code))
        }
        return .writing(account: accountFD, folder: folderFD, file: fd)
    }

    /// Moves the finished copy into place and returns its URL. Called with the lock held. If another export of the
    /// attachment stored its copy first, that one is handed out and this one discarded. The session is asked before
    /// anything is touched, and once more right before either copy is handed out.
    private func publish(
        _ fd: Int32, from temporary: String, as name: String, in folderFD: Int32, folder: URL,
        shouldHandOut: (Stage) -> Bool
    ) throws(ExportError) -> URL {
        // A writer whose session ended while it wrote changes nothing: not another session's copy, not the name.
        guard shouldHandOut(.publishing) else { throw .withdrawn }
        if let stored = try storedCopy(name, in: folderFD, folder: folder, shouldHandOut: shouldHandOut) {
            unlinkat(folderFD, temporary, 0)
            return stored
        }
        // Moved into place only if nothing is there, so nothing is ever replaced; the entry is never followed.
        guard renameatx_np(folderFD, temporary, folderFD, name, UInt32(RENAME_EXCL)) == 0 else {
            throw .io(code: Int(errno))
        }
        let url = folder.appendingPathComponent(name, isDirectory: false)
        do throws(ExportError) {
            try Self.requireSameFile(url, fd: fd)
            guard shouldHandOut(.handingOut) else { throw .withdrawn }
        } catch {
            if Self.isSameFile(name, in: folderFD, as: fd) { unlinkat(folderFD, name, 0) }
            throw error
        }
        return url
    }

    /// The copy stored under `name`, ready to hand out: a regular file with no other name on disk, with a quarantine
    /// macOS can read (restored if it can't), and still what its path names. Nil when nothing is there. Anything
    /// else at the name, or a copy whose quarantine can't be restored, throws instead, so it is never handed out
    /// and never replaced. The session is asked last, right before the copy is handed out. Called with the lock
    /// held.
    private func storedCopy(
        _ name: String, in folderFD: Int32, folder: URL, shouldHandOut: (Stage) -> Bool
    ) throws(ExportError) -> URL? {
        let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw .io(code: Int(errno == ELOOP ? EEXIST : errno))
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .io(code: Int(errno)) }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw .io(code: Int(EEXIST)) }
        // A hard link would make restoring its quarantine change a file outside the tree too.
        guard info.st_nlink == 1 else { throw .io(code: Int(EMLINK)) }
        let url = folder.appendingPathComponent(name, isDirectory: false)
        // The check a new copy gets: macOS must be able to read the quarantine, not merely find the attribute.
        try Self.requireSameFile(url, fd: fd)
        if !Self.hasQuarantineProperties(url) { try quarantine(url, fd: fd) }
        seams.beforeHandingOutStored(url)
        try Self.requireSameFile(url, fd: fd)
        guard shouldHandOut(.handingOut) else { throw .withdrawn }
        return url
    }

    /// Whether `name` has the form `export` gives its temporaries, `.<UUID>.partial`.
    static func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix("."), name.hasSuffix(".partial") else { return false }
        return UUID(uuidString: String(name.dropFirst().dropLast(".partial".count))) != nil
    }

    /// Removes temporaries no export is writing, such as one left when the app quit mid-export: only plain files
    /// named the way `export` names them, and only once no export, in this process or another, holds their lock.
    /// Called with the lock held.
    private static func reapAbandoned(in folderFD: Int32) {
        for name in childNames(of: folderFD) ?? [] where isTemporaryName(name) {
            let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            var info = stat()
            // Taking the lock proves no export, in this process or another, is writing it.
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, flock(fd, LOCK_EX | LOCK_NB) == 0,
                isSameFile(name, in: folderFD, as: fd)
            else { continue }
            unlinkat(folderFD, name, 0)
        }
    }

    /// Whether a temporary in the folder is being written, here or in another process, going by its lock.
    private static func hasExportInProgress(in folderFD: Int32) -> Bool {
        for name in childNames(of: folderFD) ?? [] where isTemporaryName(name) {
            let fd = openat(folderFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { Darwin.close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK { return true }
        }
        return false
    }

    /// A regular file, not a symlink to one.
    private static func isRegularFile(_ name: String, in parent: Int32) -> Bool {
        var info = stat()
        return fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// Whether `name` in `parent` is the file open on `fd`.
    private static func isSameFile(_ name: String, in parent: Int32, as fd: Int32) -> Bool {
        var named = stat()
        var opened = stat()
        return fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0 && fstat(fd, &opened) == 0
            && named.st_dev == opened.st_dev && named.st_ino == opened.st_ino
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
    /// target is left alone. Holds the lock throughout, so it never interleaves with pruning or an export's steps.
    public func wipe() throws(ExportError) {
        guard try Self.rootExists(directory.root) else { return }
        try Self.locked(directory.root, seams: seams, site: .wipe) {
            () throws(ExportError) in
            let rootFD = Darwin.open(directory.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard rootFD >= 0 else {
                if errno == ENOENT { return }
                throw .io(code: Int(errno))
            }
            defer { Darwin.close(rootFD) }
            guard Self.isDirectory("exports", in: rootFD) else { return try Self.clear("exports", in: rootFD) }
            let exportsFD = openat(rootFD, "exports", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard exportsFD >= 0 else {
                // Already gone is what a wipe is for.
                if errno == ENOENT { return }
                throw .wipeIncomplete(failed: 1)
            }
            defer { Darwin.close(exportsFD) }
            try Self.clear(directory.account.description, in: exportsFD)
        }
    }

    /// Removes the exports of every account, never following a symlink.
    public static func wipeAll(root: URL) throws(ExportError) {
        guard try rootExists(root) else { return }
        try locked(root, seams: Seams(), site: .wipe) { () throws(ExportError) in
            let rootFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard rootFD >= 0 else {
                if errno == ENOENT { return }
                throw .io(code: Int(errno))
            }
            defer { Darwin.close(rootFD) }
            try clear("exports", in: rootFD)
        }
    }

    // MARK: Pruning

    /// Removes this account's copies that haven't changed since `cutoff`. Nothing is followed: an old symlink inside
    /// the account's folder is unlinked itself, and a symlinked `exports` or account folder is left for `wipe()`.
    /// Each entry is judged and removed under the lock, so an export can't refresh it in between. If the shared lock
    /// can't be had, the sweep stops there and throws, leaving the rest for the next one.
    public func prune(changedBefore cutoff: Date) throws(ExportError) {
        guard let rootFD = try Self.openExistingRoot(directory.root) else { return }
        defer { Darwin.close(rootFD) }
        guard let exportsFD = try Self.openExistingDirectory("exports", in: rootFD) else { return }
        defer { Darwin.close(exportsFD) }
        guard let accountFD = try Self.openExistingDirectory(directory.account.description, in: exportsFD) else {
            return
        }
        defer { Darwin.close(accountFD) }
        let failed = try Self.removeChildren(of: accountFD, changedBefore: cutoff, root: directory.root, seams: seams)
        guard failed == 0 else { throw .wipeIncomplete(failed: failed) }
    }

    /// `prune(changedBefore:)` for every account folder, including those of accounts no longer signed in. Anything
    /// else directly under `exports` that is old goes too, a symlink in place of an account folder included: it is
    /// unlinked itself, never followed.
    public static func pruneAll(root: URL, changedBefore cutoff: Date) throws(ExportError) {
        guard let rootFD = try openExistingRoot(root) else { return }
        defer { Darwin.close(rootFD) }
        guard let exportsFD = try openExistingDirectory("exports", in: rootFD) else { return }
        defer { Darwin.close(exportsFD) }
        guard let names = childNames(of: exportsFD) else { throw .wipeIncomplete(failed: 1) }
        var failed = 0
        for name in names {
            if isDirectory(name, in: exportsFD) {
                let accountFD: Int32?
                do { accountFD = try openExistingDirectory(name, in: exportsFD) } catch {
                    failed += 1
                    continue
                }
                // Gone, or swapped for a symlink, since it was listed.
                guard let accountFD else { continue }
                defer { Darwin.close(accountFD) }
                failed += try removeChildren(of: accountFD, changedBefore: cutoff, root: root, seams: Seams())
            } else {
                failed += try removeChildren(
                    named: [name], in: exportsFD, changedBefore: cutoff, root: root, seams: Seams())
            }
        }
        guard failed == 0 else { throw .wipeIncomplete(failed: failed) }
    }

    /// Nil when `root` doesn't exist.
    private static func openExistingRoot(_ root: URL) throws(ExportError) -> Int32? {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw .io(code: Int(errno))
        }
        return fd
    }

    /// Nil when `name` is missing or isn't a real directory; a symlink is never opened.
    private static func openExistingDirectory(_ name: String, in parent: Int32) throws(ExportError) -> Int32? {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if [ENOENT, ELOOP, ENOTDIR].contains(errno) { return nil }
            throw .io(code: Int(errno))
        }
        return fd
    }

    /// Removes the children of `directoryFD` that haven't changed since `cutoff`; returns how many it couldn't.
    /// Throws, having stopped, when the shared lock can't be had.
    private static func removeChildren(
        of directoryFD: Int32, changedBefore cutoff: Date, root: URL, seams: Seams
    ) throws(ExportError) -> Int {
        guard let names = childNames(of: directoryFD) else { return 1 }
        return try removeChildren(named: names, in: directoryFD, changedBefore: cutoff, root: root, seams: seams)
    }

    private static func removeChildren(
        named names: [String], in parent: Int32, changedBefore cutoff: Date, root: URL, seams: Seams
    ) throws(ExportError) -> Int {
        var failed = 0
        for name in names {
            // Judged and removed in one step under the lock: an export claims, reuses or publishes into a folder
            // only while holding it, so a folder can't be refreshed by one between the check and its removal.
            // The lock is asked for again for each entry, behind whoever is already waiting for it. Without it the
            // sweep stops: it has been busy for all of the wait already, so waiting again for each remaining entry
            // would only hold up the sweep.
            seams.onPruneEntryAttempt(name)
            let removed =
                try locked(root, seams: seams, site: .prune) {
                    () throws(ExportError) -> Bool in
                    guard let changed = lastChange(of: name, in: parent) else { return errno == ENOENT }
                    let folderFD = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    defer { if folderFD >= 0 { Darwin.close(folderFD) } }
                    // However long an export has been writing, here or in another process, its folder stays until
                    // it's done.
                    let exporting = folderFD >= 0 && hasExportInProgress(in: folderFD)
                    guard changed < cutoff, !exporting else {
                        // Kept, but temporaries nobody is writing go, so a folder that keeps being reused doesn't
                        // keep them too.
                        if folderFD >= 0 { reapAbandoned(in: folderFD) }
                        return true
                    }
                    seams.beforePruneRemoval(name)
                    return removeEntry(name, in: parent)
                }
            if !removed { failed += 1 }
        }
        return failed
    }

    /// The latest change to `name` itself or, for a real directory, to anything directly in it: a copy that
    /// another app has just saved into counts as fresh. Nil (with `errno` set) when it can't be read.
    private static func lastChange(of name: String, in parent: Int32) -> Date? {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
        var latest = date(info.st_mtimespec)
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return latest }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        guard let children = childNames(of: fd) else { return nil }
        for child in children where fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            latest = max(latest, date(info.st_mtimespec))
        }
        return latest
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
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
        guard fd >= 0 else {
            // Removed since the check above, which is what a wipe is for.
            if errno == ENOENT { return }
            throw .wipeIncomplete(failed: 1)
        }
        let failed = removeChildren(of: fd)
        Darwin.close(fd)
        guard failed == 0 else { throw .wipeIncomplete(failed: failed) }
        guard unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT else { throw .wipeIncomplete(failed: 1) }
    }

    /// Returns how many direct children could not be removed. Symlinks are unlinked, never followed.
    private static func removeChildren(of directoryFD: Int32) -> Int {
        guard let names = childNames(of: directoryFD) else { return 1 }
        return names.filter { !removeEntry($0, in: directoryFD) }.count
    }

    /// The names in an open directory, without `.` and `..`; nil if it can't be listed.
    private static func childNames(of directoryFD: Int32) -> [String]? {
        let duplicate = dup(directoryFD)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            return nil
        }
        defer { closedir(stream) }
        // The duplicate shares the original's position, which an earlier listing left at the end.
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func removeEntry(_ name: String, in parent: Int32) -> Bool {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return unlinkat(parent, name, 0) == 0 || errno == ENOENT }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        // Removed since the check above counts as removed.
        guard fd >= 0 else { return errno == ENOENT }
        let failed = removeChildren(of: fd)
        Darwin.close(fd)
        return failed == 0 && (unlinkat(parent, name, AT_REMOVEDIR) == 0 || errno == ENOENT)
    }
}
