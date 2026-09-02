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
        let path = FileLog.defaultPath(tool: "tool")
        if FileLog.sharedDirectoryIsWritable() {
            XCTAssertEqual(path, "/Library/Managed Utilities/logs/tool.log")
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
}
