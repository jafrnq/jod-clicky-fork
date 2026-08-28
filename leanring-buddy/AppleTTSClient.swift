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
    
    public func speakText(_ text: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        
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