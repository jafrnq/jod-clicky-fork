//
//  EdgeTTSClient.swift
//  leanring-buddy
//
//  Natural neural-voice TTS via the free `edge-tts` CLI (Microsoft Edge
//  neural voices: Emma, Aria, Andrew, Brian...). No API key, no billing.
//  Falls back to Apple AVSpeechSynthesizer when the binary is unavailable.
//  Utterances are serialized so sentence-by-sentence streaming stays in
//  speech order.
//

import AVFoundation
import Foundation

public final class EdgeTTSClient: NSObject, AVAudioPlayerDelegate {
    /// A picker option: stored id is "edge:<voiceID>" so CompanionManager can
    /// route the selection to this client vs. Apple voices.
    public struct VoiceOption: Identifiable {
        public let id: String
        public let name: String
        public let voiceID: String

        public init(displayName: String, voiceID: String) {
            self.id = "edge:" + voiceID
            self.name = displayName
            self.voiceID = voiceID
        }
    }

    /// Curated natural conversational voices (Multilingual variants generally
    /// sound more human for a buddy; Neural voices are the classic set).
    public static func availableVoices() -> [VoiceOption] {
        [
            VoiceOption(displayName: "Emma (Multilingual)", voiceID: "en-US-EmmaMultilingualNeural"),
            VoiceOption(displayName: "Aria (US)", voiceID: "en-US-AriaNeural"),
            VoiceOption(displayName: "Andrew (Multilingual)", voiceID: "en-US-AndrewMultilingualNeural"),
            VoiceOption(displayName: "Brian (Multilingual)", voiceID: "en-US-BrianMultilingualNeural"),
            VoiceOption(displayName: "Jenny (US)", voiceID: "en-US-JennyNeural"),
            VoiceOption(displayName: "Ava (Multilingual)", voiceID: "en-US-AvaMultilingualNeural"),
            VoiceOption(displayName: "Guy (US)", voiceID: "en-US-GuyNeural"),
            VoiceOption(displayName: "Michelle (US)", voiceID: "en-US-MichelleNeural")
        ]
    }

    public static let defaultVoiceID = "en-US-EmmaMultilingualNeural"

    private static let binaryCandidates: [String] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/hermes-agent/venv/bin/edge-tts", isDirectory: false).path,
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/edge-tts", isDirectory: false).path,
        "/opt/homebrew/bin/edge-tts",
        "/usr/local/bin/edge-tts",
        "/usr/bin/edge-tts"
    ]

    private static let _executableURL: URL? = {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let pathCandidates = envPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("edge-tts", isDirectory: false)
        }

        return (binaryCandidates.map { URL(fileURLWithPath: $0) } + pathCandidates)
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    public static func findExecutable() -> URL? {
        return _executableURL
    }

    public static var isAvailable: Bool { findExecutable() != nil }

    private var player: AVAudioPlayer?
    private var activeProcesses: [Process] = []
    private var playContinuation: CheckedContinuation<Void, Never>?
    private var finishedEarly = false
    private let lock = NSLock()

    public var isPlaying: Bool {
        lock.lock()
        defer { lock.unlock() }
        return player?.isPlaying == true || !activeProcesses.isEmpty || playContinuation != nil
    }

    /// Speaks text using the given edge-tts voice id. Callers must serialize
    /// (CompanionManager chains sentence tasks) so utterances stay in order.
    public func speakText(_ text: String, voice voiceID: String) async throws {
        let url = try await synthesize(text: text, voiceID: voiceID)
        await play(fileAt: url)
    }

    public func stopPlayback() {
        lock.lock()
        let processes = activeProcesses
        activeProcesses.removeAll()
        let p = player
        player = nil
        let cont = playContinuation
        playContinuation = nil
        lock.unlock()

        for process in processes {
            process.terminate()
        }
        p?.stop()
        cont?.resume()
    }
    
    private func finishPlayback() {
        lock.lock()
        let cont = playContinuation
        playContinuation = nil
        if cont == nil {
            finishedEarly = true
        }
        lock.unlock()
        cont?.resume()
    }

    // MARK: - Internals

    public func synthesize(text: String, voiceID: String) async throws -> URL {
        guard let executable = EdgeTTSClient.findExecutable() else {
            throw NSError(domain: "EdgeTTSClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "edge-tts binary not found."])
        }

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge_tts_\(UUID().uuidString).mp3")

        let process = Process()
        process.executableURL = executable
        process.arguments = ["--voice", voiceID, "--text", text, "--write-media", tmpURL.path]
        let nullOutput = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = nullOutput
        process.standardError = errorPipe
        
        lock.lock()
        activeProcesses.append(process)
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            activeProcesses.removeAll { $0 === process }
            lock.unlock()
            throw error
        }
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !process.isRunning {
                continuation.resume()
                return
            }
            process.terminationHandler = { _ in continuation.resume() }
        }
        
        lock.lock()
        activeProcesses.removeAll { $0 === process }
        lock.unlock()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: tmpURL.path) else {
            throw NSError(
                domain: "EdgeTTSClient",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "edge-tts generation failed (status \(process.terminationStatus))."]
            )
        }
        return tmpURL
    }

    public func play(fileAt url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        
        lock.lock()
        self.player = p
        self.finishedEarly = false
        lock.unlock()
        
        p.play()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if self.finishedEarly {
                self.finishedEarly = false
                lock.unlock()
                continuation.resume()
                return
            }
            guard self.playContinuation == nil else {
                lock.unlock()
                continuation.resume()
                return
            }
            self.playContinuation = continuation
            lock.unlock()
        }
        
        lock.lock()
        if self.player === p {
            self.player = nil
        }
        lock.unlock()
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        lock.lock()
        let isCurrent = (self.player === player)
        lock.unlock()
        guard isCurrent else { return }
        finishPlayback()
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        lock.lock()
        let isCurrent = (self.player === player)
        lock.unlock()
        guard isCurrent else { return }
        finishPlayback()
    }
}