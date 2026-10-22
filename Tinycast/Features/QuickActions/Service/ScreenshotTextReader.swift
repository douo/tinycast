import Foundation

nonisolated enum ScreenshotTextReader {
    enum Failure: LocalizedError {
        case capture
        case recognition
        case noText

        var errorDescription: String? {
            switch self {
            case .capture:
                return String(localized: "The screenshot could not be captured.")
            case .recognition:
                return String(localized: "The text in the screenshot could not be read.")
            case .noText:
                return String(localized: "No text was found in the screenshot.")
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.tinycast.screenshot", qos: .userInitiated)

    @concurrent
    static func read(
        executable: URL = URL(fileURLWithPath: "/usr/sbin/screencapture"),
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        recognize: @Sendable (URL) async throws -> String = {
            try await ClipboardTextWorker.extract(
                at: $0, isPDF: false, executable: ClipboardTextWorker.executable)
        }
    ) async throws -> String? {
        try Task.checkCancellation()
        let directory = temporaryDirectory.appendingPathComponent("tinycast-screenshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("capture.png")
        guard try await capture(at: image, executable: executable) else { return nil }
        let text: String
        do {
            text = try await recognize(image)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw Failure.recognition
        }
        try Task.checkCancellation()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.noText
        }
        return text
    }

    private static func capture(at image: URL, executable: URL) async throws -> Bool {
        try Task.checkCancellation()
        let process = Process()
        let errors = Pipe()
        process.executableURL = executable
        // ScreenCaptureKit has no region-selection UI; the system tool supplies that interaction.
        process.arguments = ["-i", "-s", "-x", "-t", "png", image.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let exit: ProcessExit
        do { exit = try process.runObservingExit() } catch { throw Failure.capture }
        if Task.isCancelled { terminate(process) }
        let hasError = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
                    exit.wait()
                    try? errors.fileHandleForReading.close()
                    continuation.resume(returning: !diagnostics.isEmpty)
                }
            }
        } onCancel: {
            terminate(process)
        }
        try Task.checkCancellation()
        let exists = FileManager.default.fileExists(atPath: image.path)
        if !exists, !hasError, [0, 1].contains(process.terminationStatus) { return false }
        guard process.terminationStatus == 0, exists else { throw Failure.capture }
        return true
    }

    private static func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }
}
