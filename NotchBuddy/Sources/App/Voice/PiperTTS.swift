#if !APPSTORE
import Foundation
import CryptoKit

// MARK: - PiperTTS
//
// Offline Russian voice (Settings → Voice → Piper): the open Piper voice "Ruslan" run by
// sherpa-onnx on this Mac. Nothing leaves the Mac. Downloaded once on demand (~90 MB:
// the sherpa-onnx command-line tools and the voice), each archive checked against its
// SHA-256, into ~/Library/Application Support/NotchBuddy/Piper. Russian text only:
// anything else is said by the Mac voice.

@MainActor
final class PiperTTS: ObservableObject {
    static let shared = PiperTTS()

    private struct Archive: Sendable { let url: String; let sha256: String; let folder: String }
    nonisolated private static let tools = Archive(
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2",
        sha256: "b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56",
        folder: "sherpa-onnx-v1.13.8-osx-arm64-shared")
    nonisolated private static let voice = Archive(
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-ru_RU-ruslan-medium.tar.bz2",
        sha256: "0690b1cad01f86e8db9ba988af24898bdc1af774e23cb2e46b9c730269b6fd83",
        folder: "vits-piper-ru_RU-ruslan-medium")

    enum State: Equatable { case notInstalled, downloading(Double), installed, failed(String) }
    @Published private(set) var state: State = .notInstalled

    nonisolated private static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NotchBuddy/Piper")
    }
    nonisolated private static var binary: URL { root.appendingPathComponent("\(tools.folder)/bin/sherpa-onnx-offline-tts") }
    nonisolated private static var libDir: URL { root.appendingPathComponent("\(tools.folder)/lib") }
    nonisolated private static var modelDir: URL { root.appendingPathComponent(voice.folder) }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: binary.path)
            && FileManager.default.fileExists(atPath: modelDir.appendingPathComponent("ru_RU-ruslan-medium.onnx").path)
    }
    static var isActive: Bool { VoiceSettings.ttsEngine == "piper" && isInstalled }

    private init() { state = Self.isInstalled ? .installed : .notInstalled }

    // MARK: Install

    func install() {
        guard state != .installed, !(state.isDownloading) else { return }
        state = .downloading(0)
        Task {
            do {
                try FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
                try await Self.fetch(Self.tools, progress: { p in Task { @MainActor in self.state = .downloading(p * 0.3) } })
                try await Self.fetch(Self.voice, progress: { p in Task { @MainActor in self.state = .downloading(0.3 + p * 0.7) } })
                state = Self.isInstalled ? .installed : .failed("files missing after unpacking")
                appendAppLog("nb.log", "[Voice] Piper installed: \(Self.isInstalled)")
            } catch {
                state = .failed(error.localizedDescription)
                appendAppLog("nb.log", "[Voice] Piper install failed: \(error.localizedDescription)")
            }
        }
    }

    private struct InstallError: LocalizedError, Sendable { let errorDescription: String? }

    nonisolated private static func fetch(_ a: Archive, progress: @escaping @Sendable (Double) -> Void) async throws {
        let (tmp, resp) = try await URLSession.shared.download(from: URL(string: a.url)!)
        progress(0.8)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError(errorDescription: "download failed") }
        let data = try Data(contentsOf: tmp, options: .alwaysMapped)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == a.sha256 else { throw InstallError(errorDescription: "checksum mismatch") }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xjf", tmp.path, "-C", root.path]
        try tar.run()
        tar.waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
        guard tar.terminationStatus == 0 else { throw InstallError(errorDescription: "unpacking failed") }
        progress(1)
    }

    // MARK: Speech

    /// WAV for `text`, or nil (not Russian, not installed, synthesis failed) → Mac voice.
    nonisolated static func audio(for text: String) async -> Data? {
        guard text.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("piper-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = binary
        p.arguments = ["--vits-model=\(modelDir.path)/ru_RU-ruslan-medium.onnx",
                       "--vits-tokens=\(modelDir.path)/tokens.txt",
                       "--vits-data-dir=\(modelDir.path)/espeak-ng-data",
                       "--vits-length-scale=1.05",
                       "--num-threads=2",
                       "--output-filename=\(out.path)",
                       text]
        p.environment = ["DYLD_LIBRARY_PATH": libDir.path, "PATH": "/usr/bin:/bin"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            appendAppLog("nb.log", "[Voice] Piper could not start: \(error.localizedDescription)")
            return nil
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { p.waitUntilExit(); c.resume() }
        }
        defer { try? FileManager.default.removeItem(at: out) }
        guard p.terminationStatus == 0, let data = try? Data(contentsOf: out), data.count > 44 else {
            appendAppLog("nb.log", "[Voice] Piper synthesis failed (status \(p.terminationStatus))")
            return nil
        }
        return data
    }
}

extension PiperTTS.State {
    var isDownloading: Bool { if case .downloading = self { return true } else { return false } }
}
#endif
