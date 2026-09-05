import AVFoundation

public class AppleTTSClient: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var hasPendingUtterance = false
    
    public var isPlaying: Bool {
        synthesizer.isSpeaking || hasPendingUtterance
    }
    
    public override init() {
        super.init()
        synthesizer.delegate = self
    }
    
    public static let selectedVoiceIdentifierDefaultsKey = "clickyVoiceIdentifier"
    
    /// Resolved once. `AVSpeechSynthesisVoice.speechVoices()` makes a synchronous
    /// TextToSpeech/AX hop on macOS 27, so calling it from a SwiftUI body (the voice
    /// picker) can block the main thread. Cache it and prime it off-main at startup.
    private static let cachedEnglishVoices: [AVSpeechSynthesisVoice] = {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
    }()

    public static func availableEnglishVoices() -> [AVSpeechSynthesisVoice] {
        cachedEnglishVoices
    }
    
    private static func selectedSystemVoice() -> AVSpeechSynthesisVoice? {
        guard let id = UserDefaults.standard.string(forKey: selectedVoiceIdentifierDefaultsKey), !id.isEmpty else {
            return nil
        }
        if id.hasPrefix("edge:") {
            return nil
        }
        return AVSpeechSynthesisVoice(identifier: id)
    }
    
    public func speakText(_ text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.selectedSystemVoice() ?? AVSpeechSynthesisVoice(language: "en-US")
        
        hasPendingUtterance = true
        synthesizer.speak(utterance)
    }
    
    public func stopPlayback() {
        hasPendingUtterance = false
        synthesizer.stopSpeaking(at: .immediate)
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        // Not perfectly clearing hasPendingUtterance here because it might speak immediately? 
        // Actually clearing it in didFinish or didCancel is safer as requested.
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        hasPendingUtterance = false
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        hasPendingUtterance = false
    }
}