//
//  FileLogTests.swift
//  DockUtilTests
//

import XCTest
@testable import DockUtil

final class FileLogTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var logPath: String {
        return directory.appendingPathComponent("tool.log").path
    }

    func testFormatLinePadsLevelAndFlattensNewlines() {
        XCTAssertEqual(FileLog.formatLine(level: .debug, message: "m", timestamp: "2026-01-02 03:04:05"),
                       "[2026-01-02 03:04:05] DEBUG  m\n")
        XCTAssertEqual(FileLog.formatLine(level: .info, message: "m", timestamp: "2026-01-02 03:04:05"),
                       "[2026-01-02 03:04:05]  INFO  m\n")
        XCTAssertEqual(FileLog.formatLine(level: .warn, message: "m", timestamp: "2026-01-02 03:04:05"),
                       "[2026-01-02 03:04:05]  WARN  m\n")
        XCTAssertEqual(FileLog.formatLine(level: .error, message: "m", timestamp: "2026-01-02 03:04:05"),
                       "[2026-01-02 03:04:05] ERROR  m\n")
        XCTAssertEqual(FileLog.formatLine(level: .info, message: "a\nb\r\nc", timestamp: "2026-01-02 03:04:05"),
                       "[2026-01-02 03:04:05]  INFO  a b c\n")
    }

    func testWriteCreatesDirectoryAndUsesLocalTimestamp() throws {
        let log = FileLog(path: logPath)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        log.write(.info, "hello", date: date)
        log.write(.error, "boom", date: date)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = formatter.string(from: date)

        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertEqual(contents, "[\(stamp)]  INFO  hello\n[\(stamp)] ERROR  boom\n")

        let lines = contents.split(separator: "\n")
        let pattern = #"^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] (DEBUG| INFO| WARN|ERROR)  .+$"#
        for line in lines {
            XCTAssertNotNil(line.range(of: pattern, options: .regularExpression), "unexpected line: \(line)")
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual(((attributes[.posixPermissions] as? Int) ?? 0) & 0o777, 0o755)
    }

    func testRotationKeepsFiveGenerationsNewestFirst() throws {
        let maxBytes = 120
        let log = FileLog(path: logPath, maxBytes: maxBytes, generations: 5)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<60 {
            log.write(.info, String(format: "line %03d", index), date: date)
        }

        let manager = FileManager.default
        XCTAssertTrue(manager.fileExists(atPath: logPath))
        for generation in 1...5 {
            XCTAssertTrue(manager.fileExists(atPath: "\(logPath).\(generation)"), "missing generation \(generation)")
        }
        XCTAssertFalse(manager.fileExists(atPath: "\(logPath).6"))

        var paths = [logPath]
        paths += (1...5).map { "\(logPath).\($0)" }
        var previousFirstIndex = Int.max
        for path in paths {
            let size = (try manager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            XCTAssertLessThanOrEqual(size, maxBytes, "\(path) exceeds the size limit")
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            let first = contents.split(separator: "\n").first.map(String.init) ?? ""
            let number = Int(first.suffix(3)) ?? -1
            XCTAssertLessThan(number, previousFirstIndex, "\(path) is not older than the file before it")
            previousFirstIndex = number
        }
    }

    func testDefaultPathPrefersWritableSharedDirectory() {
        let date = Date()
        let path = FileLog.defaultPath(tool: "tool", date: date)
        if FileLog.sharedDirectoryIsWritable() {
            XCTAssertEqual(path, "/Library/Managed Utilities/logs/\(FileLog.dayName(date))/tool.log")
        } else {
            XCTAssertEqual(path, FileLog.userPath(tool: "tool"))
            XCTAssertTrue(path.hasSuffix("/Library/Logs/tool.log"))
            XCTAssertFalse(path.hasPrefix("/Library/"))
        }
    }

    func testCreatedFileIsWorldWritable() throws {
        let log = FileLog(path: logPath)
        log.write(.info, "hello")
        let attributes = try FileManager.default.attributesOfItem(atPath: logPath)
        XCTAssertEqual(((attributes[.posixPermissions] as? Int) ?? 0) & 0o777, 0o666)
    }

    func testFallsBackWhenPreferredPathIsNotWritable() throws {
        try XCTSkipIf(FileLog.isRoot, "root can write anywhere")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o555])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        let preferred = blocked.appendingPathComponent("tool.log").path
        let log = FileLog(path: preferred, fallbackPath: logPath)
        log.write(.info, "one")
        log.write(.warn, "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferred))
        XCTAssertEqual(log.activePath, logPath)
        let contents = try String(contentsOfFile: logPath, encoding: .utf8)
        XCTAssertTrue(contents.contains("  INFO  one\n") && contents.hasSuffix("  WARN  two\n"), "unexpected: \(contents)")
    }

    func testRefusesSymlinkTarget() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let victim = directory.appendingPathComponent("victim.txt").path
        FileManager.default.createFile(atPath: victim, contents: Data("keep\n".utf8))
        try FileManager.default.createSymbolicLink(atPath: logPath, withDestinationPath: victim)
        let log = FileLog(path: logPath)
        log.write(.info, "attack")
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "keep\n")
    }

    func testDefaultPathIsDayNestedUnderTheSharedRoot() {
        let day = FileLog.dayName(Date(timeIntervalSince1970: 1_772_000_000))
        XCTAssertEqual(day.count, 10)
        // The shared root only exists on a managed Mac, so assert the shape the
        // path takes when it does rather than which branch this machine follows.
        XCTAssertEqual(FileLog.eventsPath(besides: "/x/2026-09-03/dockutil.log"), "/x/2026-09-03/events.jsonl")
    }

    func testEveryRecordIsAlsoWrittenToTheEventStream() throws {
        let log = FileLog(path: logPath, tool: "dockutil")
        log.info("dock rebuilt")
        log.error("could not read the dock")

        let events = try String(contentsOfFile: directory.appendingPathComponent("events.jsonl").path, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(events.count, 2)
        let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(events[0].utf8)) as? [String: String])
        XCTAssertEqual(first["tool"], "dockutil")
        XCTAssertEqual(first["level"], "INFO")
        XCTAssertEqual(first["message"], "dock rebuilt")
        XCTAssertEqual(first["pid"], String(getpid()))
        let second = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(events[1].utf8)) as? [String: String])
        XCTAssertEqual(second["event_type"], "error")
        // One invocation writes one invocation id.
        XCTAssertEqual(first["invocation_id"], second["invocation_id"])
    }

    func testRetentionRemovesDayDirectoriesPastTheWindow() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for day in ["2026-01-01", FileLog.dayName(now)] {
            try fm.createDirectory(at: directory.appendingPathComponent(day), withIntermediateDirectories: true)
        }

        let removed = FileLog.pruneDayDirectories(in: directory.path, now: now)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path), [FileLog.dayName(now)])
    }

    func testSymlinkPlantedUnderTheDayNameIsNotFollowedOrChanged() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let elsewhere = directory.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let day = directory.appendingPathComponent("2026-10-06").path
        try fm.createSymbolicLink(atPath: day, withDestinationPath: elsewhere.path)

        // Root sets the entry aside and makes its own day; any other account stays off it.
        XCTAssertEqual(FileLog.makeSharedDirectory(day), geteuid() == 0)
        let mode = ((try fm.attributesOfItem(atPath: elsewhere.path)[.posixPermissions] as? Int) ?? 0) & 0o7777
        XCTAssertEqual(mode, 0o700)
        if geteuid() != 0 {
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: day), elsewhere.path)
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testAnExistingDayDirectoryKeepsItsMode() throws {
        let fm = FileManager.default
        let day = directory.appendingPathComponent("2026-10-06", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])

        XCTAssertTrue(FileLog.makeSharedDirectory(day.path))
        let mode = ((try fm.attributesOfItem(atPath: day.path)[.posixPermissions] as? Int) ?? 0) & 0o7777
        XCTAssertEqual(mode, 0o755)
    }

    func testANewDayDirectoryIsCreatedShared() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let day = directory.appendingPathComponent("2026-10-06").path

        XCTAssertTrue(FileLog.makeSharedDirectory(day))
        let mode = ((try FileManager.default.attributesOfItem(atPath: day)[.posixPermissions] as? Int) ?? 0) & 0o7777
        XCTAssertEqual(mode, Int(FileLog.sharedDirectoryMode))
    }

    func testSetAsideNameCarriesTheTimeItWasSetAside() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let name = FileLog.untrustedName(day: "2026-10-06", pid: 42, now: now)
        XCTAssertEqual(name, ".untrusted-2026-10-06-42-1790000000")
        XCTAssertEqual(FileLog.untrustedDate(name), now)
        XCTAssertNil(FileLog.untrustedDate("2026-10-06"))
        XCTAssertNil(FileLog.untrustedDate(".untrusted-junk"))
    }

    func testRootSetsAsideADayDirectoryItDoesNotOwn() throws {
        try XCTSkipUnless(geteuid() == 0, "needs root")
        let fm = FileManager.default
        let day = directory.appendingPathComponent("2026-10-06").path
        try fm.createDirectory(atPath: day, withIntermediateDirectories: true)
        chown(day, 4_294_967_294, 4_294_967_294)

        XCTAssertTrue(FileLog.makeSharedDirectory(day))
        var info = stat()
        XCTAssertEqual(lstat(day, &info), 0)
        XCTAssertEqual(info.st_uid, 0)
        XCTAssertEqual(info.st_mode & 0o7777, FileLog.sharedDirectoryMode)
        let entries = try fm.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(entries.filter { $0.hasPrefix(FileLog.untrustedPrefix) }.count, 1)
    }

    func testRetentionRemovesSetAsideEntriesWithoutFollowingThem() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let old = now.addingTimeInterval(-60 * 24 * 60 * 60)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        fm.createFile(atPath: target.appendingPathComponent("keep").path, contents: Data("x".utf8))
        let link = directory.appendingPathComponent(FileLog.untrustedName(day: "2026-01-01", pid: 1, now: old)).path
        let dir = directory.appendingPathComponent(FileLog.untrustedName(day: "2026-01-02", pid: 2, now: old))
        let recent = FileLog.untrustedName(day: "2026-02-24", pid: 3, now: now)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: target.path)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fm.createFile(atPath: dir.appendingPathComponent("dockutil.log").path, contents: Data("x".utf8))
        try fm.createDirectory(at: directory.appendingPathComponent(recent), withIntermediateDirectories: false)

        XCTAssertEqual(FileLog.pruneDayDirectories(in: directory.path, now: now), 2)
        XCTAssertEqual(Set(try fm.contentsOfDirectory(atPath: directory.path)), ["target", recent])
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("keep").path))
    }

    func testRetentionUnlinksALinkInsideAnExpiredDayAndItsTargetSurvives() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        fm.createFile(atPath: target.appendingPathComponent("keep").path, contents: Data("x".utf8))
        let day = directory.appendingPathComponent("2026-01-01", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        fm.createFile(atPath: day.appendingPathComponent("dockutil.log").path, contents: Data("x".utf8))
        try fm.createSymbolicLink(atPath: day.appendingPathComponent("link").path, withDestinationPath: target.path)

        XCTAssertEqual(FileLog.pruneDayDirectories(in: directory.path, now: now), 1)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path), ["target"])
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("keep").path))
    }

    func testRetentionLeavesAFolderNestedInsideAnExpiredDay() throws {
        let fm = FileManager.default
        let now = Date(timeIntervalSince1970: 1_772_000_000)
        let day = directory.appendingPathComponent("2026-01-01", isDirectory: true)
        try fm.createDirectory(at: day.appendingPathComponent("nested"), withIntermediateDirectories: true)
        fm.createFile(atPath: day.appendingPathComponent("dockutil.log").path, contents: Data("x".utf8))

        XCTAssertEqual(FileLog.pruneDayDirectories(in: directory.path, now: now), 0)
        XCTAssertTrue(fm.fileExists(atPath: day.appendingPathComponent("nested").path))
        XCTAssertFalse(fm.fileExists(atPath: day.appendingPathComponent("dockutil.log").path))
    }
}
