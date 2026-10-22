import Foundation
import Synchronization

@main
@MainActor
struct ScreenshotTextTests {
    static var failures = 0
    static var passes = 0

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-screenshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captures = directory.appendingPathComponent("captures")
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("capture")

        try script("printf image > \"$6\"", at: executable)
        let text = try await ScreenshotTextReader.read(executable: executable, temporaryDirectory: captures) { url in
            guard try String(contentsOf: url, encoding: .utf8) == "image" else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return "Hello\n你好"
        }
        expect(text == "Hello\n你好", "recognized text reaches translation unchanged")
        try expectEmpty(captures)

        for status in [0, 1] {
            try script("exit \(status)", at: executable)
            let cancelled = try await ScreenshotTextReader.read(
                executable: executable, temporaryDirectory: captures,
                recognize: { _ in throw CocoaError(.fileReadUnknown) })
            expect(cancelled == nil, "cancelled capture skips OCR")
            try expectEmpty(captures)
        }

        try script("echo 'capture failed' >&2\nexit 1", at: executable)
        await expectFailure(.capture) {
            try await ScreenshotTextReader.read(executable: executable, temporaryDirectory: captures)
        }
        try expectEmpty(captures)
        await expectFailure(.capture) {
            try await ScreenshotTextReader.read(
                executable: directory.appendingPathComponent("missing"), temporaryDirectory: captures)
        }
        try expectEmpty(captures)

        try script("printf image > \"$6\"", at: executable)
        await expectFailure(.noText) {
            try await ScreenshotTextReader.read(
                executable: executable, temporaryDirectory: captures, recognize: { _ in " \n\t" })
        }
        try expectEmpty(captures)
        await expectFailure(.recognition) {
            try await ScreenshotTextReader.read(
                executable: executable, temporaryDirectory: captures,
                recognize: { _ in throw CocoaError(.fileReadCorruptFile) })
        }
        try expectEmpty(captures)

        let enteredOCR = Mutex(false)
        let recognition = Task {
            try await ScreenshotTextReader.read(executable: executable, temporaryDirectory: captures) { _ in
                enteredOCR.withLock { $0 = true }
                try? await Task.sleep(for: .seconds(30))
                return "A late result"
            }
        }
        let recognitionDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !enteredOCR.withLock({ $0 }), ContinuousClock.now < recognitionDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        expect(enteredOCR.withLock { $0 }, "recognition started")
        recognition.cancel()
        await expectCancelled(recognition)
        try expectEmpty(captures)

        try script("echo $$ > \"$6\"\nexec /bin/sleep 30", at: executable)
        let capture = Task {
            try await ScreenshotTextReader.read(executable: executable, temporaryDirectory: captures)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var pid: Int32?
        while pid == nil, ContinuousClock.now < deadline {
            if let run = try FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil).first,
                let value = try? String(contentsOf: run.appendingPathComponent("capture.png"), encoding: .utf8)
            {
                pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        expect(pid != nil, "capture process started")
        capture.cancel()
        await expectCancelled(capture)
        if let pid { expect(kill(pid, 0) != 0, "cancelled capture process is reaped") }
        try expectEmpty(captures)

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func expectFailure(
        _ expected: ScreenshotTextReader.Failure, operation: () async throws -> String?
    ) async {
        do {
            _ = try await operation()
            expect(false, "expected \(expected)")
        } catch let failure as ScreenshotTextReader.Failure {
            expect(failure == expected, "failure reports \(expected)")
        } catch { expect(false, "unexpected failure: \(error)") }
    }

    static func expectCancelled(_ task: Task<String?, Error>) async {
        do {
            _ = try await task.value
            expect(false, "cancellation must not return recognized text")
        } catch is CancellationError {
            expect(true, "cancellation propagates")
        } catch { expect(false, "cancellation must not become a user-facing failure") }
    }

    static func script(_ source: String, at url: URL) throws {
        try ("#!/bin/sh\n" + source + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func expectEmpty(_ directory: URL) throws {
        expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "temporary capture removed")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if condition { passes += 1 } else { failures += 1; print("FAIL: \(message)") }
    }
}
