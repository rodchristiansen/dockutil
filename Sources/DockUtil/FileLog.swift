//
//  FileLog.swift
//
//  Append-only file log for small utilities that are invoked by scripts and
//  packages. Console output is unchanged; this file is the audit trail.
//
//  Location   /Library/Managed Utilities/logs/<yyyy-MM-dd>/<tool>.log whenever
//             that shared directory is writable by the calling process. A
//             utility is invoked too often to justify a directory per run, so
//             the day directory is its session: the tool's lines go to
//             <tool>.log and their structured form to events.jsonl beside it,
//             shared by every tool writing into that root. The installer
//             creates the root root:wheel mode 1777 (world-writable, sticky)
//             so a root-context run and a user-context run append to the same
//             files, and day directories are created the same way by whichever
//             context gets there first. When the directory is absent or not
//             writable, or the file cannot be opened, the log falls back to
//             ~/Library/Logs/<tool>.log.
//  Line       [yyyy-MM-dd HH:mm:ss] LEVEL  message   (local time, level
//             left-padded to five characters: DEBUG, INFO, WARN, ERROR)
//  Rotation   when a write would take the file past 5 MB it is renamed
//             <tool>.log.1 and older generations shift to .2 .. .5; five
//             generations are kept, newest is .1. Only the file's owner (or
//             root) rotates; in the sticky shared directory another user
//             keeps appending to the current file instead.
//  Safety     the file is opened with O_NOFOLLOW and must be a regular file
//             with a single link, so a planted symlink or hard link in the
//             shared directory is never written through. Files are created
//             mode 0666 so every context can append.
//
//  Foundation and libc only. A failure to log is silent so the tool's own
//  behaviour is never affected by the log.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public final class FileLog: @unchecked Sendable {

    public enum Level: String, CaseIterable {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    public static let defaultMaxBytes = 5 * 1024 * 1024
    public static let defaultGenerations = 5
    public static let rootDirectory = "/Library/Managed Utilities/logs"
    /// Day directories older than this are removed the first time a process logs.
    public static let retentionDays = 30
    public static let sharedDirectoryMode: mode_t = 0o1777
    public static let sharedFileMode: mode_t = 0o666

    /// The preferred path. `activePath` is where records actually land once a
    /// write has had to fall back.
    public let path: String
    public let fallbackPath: String?
    public let maxBytes: Int
    public let generations: Int

    private let lock = NSLock()
    private let formatter: DateFormatter
    private let dayFormatter: DateFormatter
    private var fellBack = false
    /// The tool name, used to label records and, when this log resolves its own
    /// path, to build it. A log constructed with an explicit path keeps that
    /// path and never re-resolves.
    private let tool: String?
    private let resolvesPath: Bool
    /// Where the last record went. Re-resolved per write for a tool log, so a
    /// process still running at midnight rolls onto the new day directory.
    private var resolved: String
    /// Distinguishes this process's records from another's in a file several
    /// invocations share.
    private let invocation = UUID().uuidString
    private static var pruned = false
    private static let pruneLock = NSLock()

    /// Logs to the conventional location for `tool` (see the header).
    public convenience init(tool: String) {
        self.init(path: FileLog.defaultPath(tool: tool), fallbackPath: FileLog.userPath(tool: tool),
                  tool: tool, resolvesPath: true)
    }

    /// Logs to an explicit path. `maxBytes` and `generations` exist for tests.
    public init(path: String, fallbackPath: String? = nil, maxBytes: Int = FileLog.defaultMaxBytes, generations: Int = FileLog.defaultGenerations, tool: String? = nil, resolvesPath: Bool = false) {
        self.path = path
        self.tool = tool
        self.resolvesPath = resolvesPath
        self.resolved = path
        self.fallbackPath = (fallbackPath == path) ? nil : fallbackPath
        self.maxBytes = Swift.max(1, maxBytes)
        self.generations = Swift.max(0, generations)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.formatter = formatter
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        self.dayFormatter = dayFormatter
    }

    /// Where records currently go: `path`, or `fallbackPath` after a fallback.
    public var activePath: String {
        lock.lock()
        defer { lock.unlock() }
        return fellBack ? (fallbackPath ?? path) : resolved
    }

    /// The shared path when the shared directory can be written by this
    /// process (root creates it if missing), otherwise the per-user path.
    /// The shared form is day-nested: the day directory is the utility tier's
    /// session, and every tool writing into the root shares it.
    public static func defaultPath(tool: String, date: Date = Date()) -> String {
        if sharedDirectoryIsWritable() {
            return rootDirectory + "/" + dayName(date) + "/" + tool + ".log"
        }
        return userPath(tool: tool)
    }

    /// The day directory's name, `yyyy-MM-dd` in local time.
    public static func dayName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// The structured stream beside a log file: one JSON object per line,
    /// shared by every tool writing into that directory.
    public static func eventsPath(besides target: String) -> String {
        return (target as NSString).deletingLastPathComponent + "/events.jsonl"
    }

    /// Removes day directories under `rootDirectory` older than the retention
    /// window. Best-effort: in the shared sticky root another context's
    /// directories are not this process's to remove.
    @discardableResult
    public static func pruneDayDirectories(in directory: String = rootDirectory, now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory),
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: now) else { return 0 }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        var removed = 0
        for entry in entries {
            guard let day = f.date(from: entry), day < cutoff else { continue }
            let full = (directory as NSString).appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if (try? fm.removeItem(atPath: full)) != nil { removed += 1 }
        }
        return removed
    }

    public static func userPath(tool: String) -> String {
        return NSHomeDirectory() + "/Library/Logs/" + tool + ".log"
    }

    public static var isRoot: Bool {
        return geteuid() == 0
    }

    /// True when `rootDirectory` exists (or root just created it) and this
    /// process may create files in it.
    public static func sharedDirectoryIsWritable() -> Bool {
        if isRoot {
            ensureSharedDirectory()
        }
        var info = stat()
        guard stat(rootDirectory, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
        return access(rootDirectory, W_OK | X_OK) == 0
    }

    /// Creates the shared directory root:wheel mode 1777 when it is missing.
    /// Root only; a no-op otherwise.
    public static func ensureSharedDirectory() {
        guard isRoot else { return }
        var info = stat()
        if stat(rootDirectory, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o7777) != sharedDirectoryMode {
                chmod(rootDirectory, sharedDirectoryMode)
            }
            return
        }
        let parent = (rootDirectory as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755, .ownerAccountID: 0, .groupOwnerAccountID: 0])
        if mkdir(rootDirectory, sharedDirectoryMode) == 0 {
            chown(rootDirectory, 0, 0)
            chmod(rootDirectory, sharedDirectoryMode)
        }
    }

    public func debug(_ message: String) { write(.debug, message) }
    public func info(_ message: String) { write(.info, message) }
    public func warn(_ message: String) { write(.warn, message) }
    public func error(_ message: String) { write(.error, message) }

    public func write(_ level: Level, _ message: String, date: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        if resolvesPath, let tool = tool, !fellBack {
            // Re-resolved every record, so a process still running at midnight
            // rolls onto the new day directory rather than the one it started in.
            resolved = FileLog.defaultPath(tool: tool, date: date)
        }
        let line = FileLog.formatLine(level: level, message: message, timestamp: formatter.string(from: date))
        guard let data = line.data(using: .utf8) else { return }
        if !fellBack, append(data, to: resolved) {
            writeEvent(level: level, message: message, date: date, beside: resolved)
            return
        }
        guard let fallback = fallbackPath else { return }
        fellBack = true
        if append(data, to: fallback) {
            writeEvent(level: level, message: message, date: date, beside: fallback)
        }
    }

    /// Appends the same record to events.jsonl beside the log. Utilities share
    /// one stream per directory, so each record names its tool, its process and
    /// the invocation that wrote it.
    private func writeEvent(level: Level, message: String, date: Date, beside target: String) {
        guard let toolName = tool else { return }
        let record: [String: String] = [
            "timestamp": FileLog.isoFormatter.string(from: date),
            "level": level.rawValue,
            "event_type": level == .error ? "error" : "message",
            "tool": toolName,
            "pid": String(getpid()),
            "invocation_id": invocation,
            "message": message
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        guard let payload = line.data(using: .utf8) else { return }
        _ = append(payload, to: FileLog.eventsPath(besides: target))
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Builds one log line. Newlines inside `message` are flattened so a
    /// line in the file is always one record.
    public static func formatLine(level: Level, message: String, timestamp: String) -> String {
        let name = level.rawValue
        let padded = String(repeating: " ", count: Swift.max(0, 5 - name.count)) + name
        let flat = message
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return "[\(timestamp)] \(padded)  \(flat)\n"
    }

    // MARK: - File handling

    private func ensureDirectory(for target: String) {
        let directory = (target as NSString).deletingLastPathComponent
        if directory == FileLog.rootDirectory {
            FileLog.ensureSharedDirectory()
            return
        }
        // A day directory inside the shared root is created world-writable and
        // sticky like the root itself, by whichever context gets there first,
        // so every other context can write its own records into it. Retention
        // runs once per process, the first time it needs the directory.
        if (directory as NSString).deletingLastPathComponent == FileLog.rootDirectory {
            FileLog.ensureSharedDirectory()
            var info = stat()
            if stat(directory, &info) != 0 {
                if mkdir(directory, FileLog.sharedDirectoryMode) == 0 {
                    chmod(directory, FileLog.sharedDirectoryMode)
                    if FileLog.isRoot { chown(directory, 0, 0) }
                }
            } else if (info.st_mode & 0o7777) != FileLog.sharedDirectoryMode, info.st_uid == geteuid() {
                chmod(directory, FileLog.sharedDirectoryMode)
            }
            FileLog.pruneOnce()
            return
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue {
            return
        }
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        if FileLog.isRoot {
            attributes[.ownerAccountID] = 0
            attributes[.groupOwnerAccountID] = 0
        }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: attributes)
    }

    /// Appends `data` to `target`. Returns false when the file could not be
    /// opened or is not a plain, single-linked regular file.
    private func append(_ data: Data, to target: String) -> Bool {
        ensureDirectory(for: target)
        guard var descriptor = openForAppend(target) else { return false }
        let size = Int(lseek(descriptor, 0, SEEK_END))
        if size > 0 && size + data.count > maxBytes && mayRotate(descriptor) {
            close(descriptor)
            rotate(target)
            guard let reopened = openForAppend(target) else { return false }
            descriptor = reopened
        }
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = posixWrite(descriptor, base + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        close(descriptor)
        return true
    }

    /// Opens `target` for appending without following a symlink, refuses
    /// anything that is not a regular file with one link, and widens a file
    /// this process owns to mode 0666 so other contexts can append too.
    private func openForAppend(_ target: String) -> Int32? {
        let descriptor = open(target, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, FileLog.sharedFileMode)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            close(descriptor)
            return nil
        }
        if info.st_uid == geteuid(), (info.st_mode & 0o777) != FileLog.sharedFileMode {
            fchmod(descriptor, FileLog.sharedFileMode)
        }
        return descriptor
    }

    /// Runs retention the first time this process writes into the shared root.
    private static func pruneOnce() {
        pruneLock.lock()
        defer { pruneLock.unlock() }
        guard !pruned else { return }
        pruned = true
        pruneDayDirectories()
    }

    private func mayRotate(_ descriptor: Int32) -> Bool {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        return FileLog.isRoot || info.st_uid == geteuid()
    }

    private func rotate(_ target: String) {
        let manager = FileManager.default
        guard generations > 0 else {
            try? manager.removeItem(atPath: target)
            return
        }
        let oldest = "\(target).\(generations)"
        if manager.fileExists(atPath: oldest) {
            try? manager.removeItem(atPath: oldest)
        }
        if generations > 1 {
            for index in stride(from: generations - 1, through: 1, by: -1) {
                let from = "\(target).\(index)"
                if manager.fileExists(atPath: from) {
                    try? manager.moveItem(atPath: from, toPath: "\(target).\(index + 1)")
                }
            }
        }
        try? manager.moveItem(atPath: target, toPath: "\(target).1")
    }
}

private func posixWrite(_ descriptor: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Int {
    return write(descriptor, pointer, count)
}
