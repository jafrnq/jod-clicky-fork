//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import PostHog
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Video State (shared across all screen overlays)

    @Published var onboardingVideoPlayer: AVPlayer?
    @Published var showOnboardingVideo: Bool = false
    @Published var onboardingVideoOpacity: Double = 0.0
    private var onboardingVideoEndObserver: NSObjectProtocol?
    private var onboardingDemoTimeObserver: Any?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor after the onboarding video ends.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    private let responseOverlay = CompanionResponseOverlayManager()

    private lazy var claudeAgentSDK = ClaudeAgentSDKAPI(model: selectedModel, workingDirectory: AgentCommandRunner.workspaceURL)
    private let appleTTS = AppleTTSClient()
    private let edgeTTS = EdgeTTSClient()
    
    private var displayedResponseText = ""
    /// True when the selected voice is an Edge neural voice (id starts with "edge:").
    private var selectedEdgeVoiceID: String? {
        guard EdgeTTSClient.isAvailable,
              let id = selectedVoiceIdentifier, id.hasPrefix("edge:") else { return nil }
        return String(id.dropFirst("edge:".count))
    }

    private var pendingSpokenSentences = 0

    private var ttsIsPlaying: Bool {
        appleTTS.isPlaying || edgeTTS.isPlaying || pendingSpokenSentences > 0
    }

    private func stopTTS() {
        appleTTS.stopPlayback()
        edgeTTS.stopPlayback()
    }

    /// Routes an utterance to the selected TTS engine: Edge neural voice when
    /// chosen and available, Apple AVSpeechSynthesizer otherwise.
    private func speakViaTTS(_ text: String) async throws {
        if let edgeVoice = selectedEdgeVoiceID, EdgeTTSClient.isAvailable {
            try await edgeTTS.speakText(text, voice: edgeVoice)
        } else {
            try await appleTTS.speakText(text)
        }
    }

    // MARK: - Streaming speech

    /// Buffer of streamed response text not yet handed to TTS (waits for a
    /// sentence terminator so we don't speak half sentences).
    private var streamedSpeechBuffer = ""
    /// Guards the sentence TTS task chain so a cancelled turn stops queued
    /// sentences from continuing to play while the user speaks again.
    private var ttsGeneration = UUID()
    private var speechChain: Task<Void, Never>?
    private var speechFlushTask: Task<Void, Never>?
    private var didStartSpeaking = false

    /// Resets the streaming pipeline when a new interaction begins.
    private func resetSpeechPipeline() {
        ttsGeneration = UUID()
        speechChain?.cancel()
        speechChain = nil
        speechFlushTask?.cancel()
        speechFlushTask = nil
        streamedSpeechBuffer = ""
        displayedResponseText = ""
        responseOverlay.hideOverlay()
        didStartSpeaking = false
        stopTTS()
    }

    /// Appends a streamed chunk and hands complete sentences (ending in
    /// `.`, `!`, `?`, or newline) to TTS immediately, in order.
    private func handleStreamedTextChunk(_ chunk: String) {
        streamedSpeechBuffer += chunk
        while let (sentence, remainder) = Self.popFirstCompleteSentence(from: streamedSpeechBuffer) {
            enqueueSpokenSentence(sentence)
            streamedSpeechBuffer = remainder
        }
        
        speechFlushTask?.cancel()
        let currentGen = ttsGeneration
        speechFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, let self, self.ttsGeneration == currentGen else { return }
            let buffer = self.streamedSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !buffer.isEmpty, !buffer.contains("[POINT:"), !buffer.contains("[RUN:") {
                let stripped = buffer.replacingOccurrences(of: #"\[POINT:[^\]]*\]"#, with: "", options: .regularExpression)
                                     .replacingOccurrences(of: #"\[RUN:[^\]]*\]"#, with: "", options: .regularExpression)
                if !stripped.isEmpty {
                    self.enqueueSpokenSentence(stripped)
                    self.streamedSpeechBuffer = ""
                }
            }
        }
    }

    /// Splits the first complete sentence off the buffer using the terminator
    /// characters, stripping any fully-formed [POINT:...] tags first. Never
    /// splits inside an incomplete tag (it may contain periods in a label).
    static func popFirstCompleteSentence(from text: String) -> (sentence: String, remainder: String)? {
        var work = text
        work = work.replacingOccurrences(of: #"\[POINT:[^\]]*\]"#, with: "", options: .regularExpression)
                   .replacingOccurrences(of: #"\[RUN:[^\]]*\]"#, with: "", options: .regularExpression)

        // If an incomplete tag remains, only allow splitting the prefix before it.
        let pointOpen = work.range(of: "[POINT:")
        let runOpen = work.range(of: "[RUN:")
        if let open = [pointOpen, runOpen].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let prefix = String(work[..<open.lowerBound])
            guard let (sentence, prefixRemainder) = Self.splitFirstCompleteSentence(from: prefix) else { return nil }
            // Keep the un-split prefix remainder plus the tag portion in the buffer.
            return (sentence, prefixRemainder + String(work[open.lowerBound...]))
        }

        guard let (sentence, remainder) = Self.splitFirstCompleteSentence(from: work) else { return nil }
        return (sentence, remainder)
    }

    static func splitFirstCompleteSentence(from text: String) -> (sentence: String, remainder: String)? {
        var searchRange = text.startIndex..<text.endIndex
        while searchRange.lowerBound < text.endIndex {
            guard let terminator = text[searchRange].firstIndex(where: { 
                $0 == "." || $0 == "!" || $0 == "?" || $0 == "\n" || 
                $0 == "," || $0 == ";" || $0 == ":" || $0 == "—" 
            }) else { return nil }
            
            let end = text.index(after: terminator)
            let candidate = String(text[..<end])
            let char = text[terminator]
            let isSoft = char == "," || char == ";" || char == ":" || char == "—"
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if !isSoft || trimmed.count >= 30 {
                if !trimmed.isEmpty {
                    return (trimmed, String(text[end...]))
                } else {
                    return splitFirstCompleteSentence(from: String(text[end...]))
                }
            }
            searchRange = end..<text.endIndex
        }
        return nil
    }

    /// Queues one sentence on the serial speech chain. Sets the voice state to
    /// responding the moment the first sentence starts, without waiting for the
    /// full response.
    private func enqueueSpokenSentence(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !Task.isCancelled else { return }

        if !didStartSpeaking {
            didStartSpeaking = true
            voiceState = .responding
        }

        pendingSpokenSentences += 1

        let generation = ttsGeneration
        let previous = speechChain
        let edgeVoice = selectedEdgeVoiceID
        let shouldPrefetch = edgeVoice != nil && pendingSpokenSentences <= 3
        let synthesis: Task<URL?, Never>? = shouldPrefetch ? Task { [weak self] in
            guard let self, let v = edgeVoice else { return nil }
            return try? await self.edgeTTS.synthesize(text: trimmed, voiceID: v)
        } : nil

        speechChain = Task { [weak self] in
            defer { self?.pendingSpokenSentences -= 1 }
            let url = await synthesis?.value
            _ = await previous?.value
            guard let self, self.ttsGeneration == generation, !Task.isCancelled else {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            
            if let url {
                await self.edgeTTS.play(fileAt: url)
            } else if let v = self.selectedEdgeVoiceID {
                if let u = try? await self.edgeTTS.synthesize(text: trimmed, voiceID: v) {
                    await self.edgeTTS.play(fileAt: u)
                }
            } else {
                try? await self.appleTTS.speakText(trimmed)
            }
        }
    }

    /// Conversation history so Claude remembers prior exchanges within a session.
    /// Each entry is the user's transcript and Claude's response.
    private var conversationHistory: [(userTranscript: String, assistantResponse: String)] = []

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var toggleDictateModeShortcutCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var pendingScreenCaptureTask: Task<[CompanionScreenCapture], Error>?
    private var pendingRegionSelection: CGRect?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-haiku-4-5"

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
        claudeAgentSDK.model = model
    }
    
    @Published var selectedVoiceIdentifier: String? = {
        if let saved = UserDefaults.standard.string(forKey: AppleTTSClient.selectedVoiceIdentifierDefaultsKey),
           !saved.isEmpty {
            return saved
        }
        // Default to the natural Edge neural voice when installed.
        return EdgeTTSClient.isAvailable ? "edge:" + EdgeTTSClient.defaultVoiceID : nil
    }()
    func setSelectedVoiceIdentifier(_ identifier: String?) {
        selectedVoiceIdentifier = identifier
        if let id = identifier, !id.isEmpty {
            UserDefaults.standard.set(id, forKey: AppleTTSClient.selectedVoiceIdentifierDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: AppleTTSClient.selectedVoiceIdentifierDefaultsKey)
        }
    }
    
    @Published var isDictateModeEnabled = UserDefaults.standard.bool(forKey: "clickyDictateMode")
    func setDictateModeEnabled(_ enabled: Bool) {
        isDictateModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "clickyDictateMode")
    }

    @Published var isAgentModeEnabled = UserDefaults.standard.bool(forKey: "clickyAgentMode")
    func setAgentModeEnabled(_ enabled: Bool) {
        isAgentModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "clickyAgentMode")
        claudeAgentSDK.agentModeEnabled = enabled
        claudeAgentSDK.maxOutputTokens = enabled ? 600 : 180
    }
    
    private func toggleDictateModeFromShortcut() {
        let on = !isDictateModeEnabled
        setDictateModeEnabled(on)
        
        let wasVisible = !displayedResponseText.isEmpty
        if !wasVisible {
            responseOverlay.showOverlayAndBeginStreaming()
        }
        
        responseOverlay.updateStreamingText("dictate mode " + (on ? "on" : "off"))
        
        if !wasVisible {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled else { return }
                self?.responseOverlay.hideOverlay()
                self?.scheduleTransientHideIfNeeded()
            }
        }
    }

    /// User preference for whether the Clicky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has submitted their email during onboarding.
    @Published var hasSubmittedEmail: Bool = UserDefaults.standard.bool(forKey: "hasSubmittedEmail")

    /// Submits the user's email to FormSpark and identifies them in PostHog.
    func submitEmail(_ email: String) {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty else { return }

        hasSubmittedEmail = true
        UserDefaults.standard.set(true, forKey: "hasSubmittedEmail")

        // Identify user in PostHog
        PostHogSDK.shared.identify(trimmedEmail, userProperties: [
            "email": trimmedEmail
        ])

        // Submit to FormSpark
        Task {
            var request = URLRequest(url: URL(string: "https://submit-form.com/RWbGJxmIs")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["email": trimmedEmail])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    func start() {
        AgentCommandRunner.ensureWorkspaceExists()
        // Push the persisted agent-mode flag into the SDK so a relaunch with the
        // mode ON gets the matching prompt, token budget, and tool env.
        setAgentModeEnabled(isAgentModeEnabled)
        refreshAllPermissions()
        print("🔑 Clicky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission), onboarded: \(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()        // Eagerly touch the Claude SDK so its warm-up handshake completes
        // well before the onboarding demo fires at ~40s into the video.
        claudeAgentSDK.warmUp(systemPrompt: Self.companionVoiceResponseSystemPrompt(agentMode: isAgentModeEnabled))

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and intro video play.
    func triggerOnboarding() {
        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        ClickyAnalytics.trackOnboardingStarted()

        // Play Besaid theme at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding video
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and video.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        ClickyAnalytics.trackOnboardingReplayed()
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("⚠️ Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("⚠️ Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }



    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            ClickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            ClickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            ClickyAnalytics.trackAllPermissionsGranted()
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    ClickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .throttle(for: .milliseconds(40), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
            
        toggleDictateModeShortcutCancellable = globalPushToTalkShortcutMonitor
            .dictateModeTogglePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                self?.toggleDictateModeFromShortcut()
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            // Don't register push-to-talk while the onboarding video is playing
            guard !showOnboardingVideo else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and TTS from a previous utterance
            currentResponseTask?.cancel()
            resetSpeechPipeline()
            clearDetectedElementLocation()

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            ClickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingScreenCaptureTask?.cancel()
            if NSEvent.modifierFlags.contains(.shift) {
                Task { @MainActor in
                    self.pendingRegionSelection = await RegionSelectionOverlayManager.shared.startSelection()
                }
            }
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        guard let self = self else { return }
                        self.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        ClickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        
                        if self.isDictateModeEnabled {
                            let text = finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else {
                                self.voiceState = .idle
                                self.scheduleTransientHideIfNeeded()
                                return
                            }
                            
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(text, forType: .string)
                            
                            Task {
                                do {
                                    if !WindowPositionManager.hasAccessibilityPermission() {
                                        throw NSError(domain: "Dictate", code: 1, userInfo: nil)
                                    }
                                    
                                    try await Task.sleep(nanoseconds: 150_000_000)
                                    
                                    let source = CGEventSource(stateID: .combinedSessionState)
                                    let vKey = CGKeyCode(9) // kVK_ANSI_V
                                    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
                                    keyDown?.flags = .maskCommand
                                    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
                                    keyUp?.flags = .maskCommand
                                    
                                    keyDown?.post(tap: .cghidEventTap)
                                    keyUp?.post(tap: .cghidEventTap)
                                    
                                    self.voiceState = .idle
                                    self.scheduleTransientHideIfNeeded()
                                } catch {
                                    print("⚠️ Dictate paste failed: \(error)")
                                    self.voiceState = .responding
                                    do {
                                        try await self.speakViaTTS("Copied to clipboard.")
                                        // Wait until finished or transient hide handles it
                                    } catch {
                                        print("⚠️ Dictate TTS fallback failed")
                                    }
                                    self.voiceState = .idle
                                    self.scheduleTransientHideIfNeeded()
                                }
                            }
                        } else {
                            self.sendTranscriptToClaudeWithScreenshot(transcript: finalTranscript)
                        }
                    }
                )
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            ClickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            
            Task { @MainActor in
                RegionSelectionOverlayManager.shared.cancelSelection()
                let regionToCapture = RegionSelectionOverlayManager.shared.takeLastCompletedRect() ?? self.pendingRegionSelection
                self.pendingRegionSelection = nil
                self.pendingScreenCaptureTask = Task {
                    if let region = regionToCapture {
                        return [try await CompanionScreenCaptureUtility.captureRegionAsJPEG(globalRect: region)]
                    } else {
                        return try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                    }
                }
            }
            
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    static func companionVoiceResponseSystemPrompt(agentMode: Bool) -> String {
        var base = """
        you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

        rules:
        - one or two sentences. hard stop. only go longer if they explicitly ask you to explain more.
        - all lowercase, casual, warm. no emojis, no lists, no markdown. write for the ear.
        - do NOT narrate or describe the screen. only mention something on screen if it directly answers what they asked.
        - answer the question, then stop. no follow-up questions, no suggestions, no "you could also".
        - never say "simply" or "just". don't read code verbatim.
        - write for the ear. spell out small numbers.
        - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.
        """
        
        if agentMode {
            base += "\n        - you can look things up on the web.\n        - if the user asks you to DO something on the machine (open an app, run a command), put the exact shell command as [RUN:open -a \"Microsoft Excel\"] just before the point tag and say in one short sentence what you're about to do. never use the Bash tool. one RUN tag max.\n"
            
            let notesURL = AgentCommandRunner.workspaceURL.appendingPathComponent("NOTES.md")
            if let notes = try? String(contentsOf: notesURL, encoding: .utf8) {
                base += "\n\nWorkspace Notes:\n" + String(notes.prefix(2000))
            }
        } else {
            base += "\n        - you cannot run commands, click, launch apps, or change anything on this machine. you only look and talk. never say what you \"can\" or \"can't\" do for them — describe and advise. if you can't see something, say you can't see it, don't conclude it isn't installed.\n"
        }
        
        base += "\n" + """
        element pointing:
        you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

        don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

        when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

        format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

        if pointing wouldn't help, append [POINT:none].

        examples:
        - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
        - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. [POINT:none]"
        """
        return base
    }

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Claude,
    /// and plays the response aloud via Apple TTS. The cursor stays in
    /// the spinner/processing state until TTS audio begins playing.
    /// Claude's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToClaudeWithScreenshot(transcript: String) {
        currentResponseTask?.cancel()
        resetSpeechPipeline()

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                // Capture all connected screens so the AI has full context
                let screenCaptures: [CompanionScreenCapture]
                if let captureTask = pendingScreenCaptureTask {
                    screenCaptures = try await captureTask.value
                } else {
                    screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                }
                pendingScreenCaptureTask = nil

                guard !Task.isCancelled else { return }

                // Build image labels with the actual screenshot pixel dimensions
                // so Claude's coordinate space matches the image it sees. We
                // scale from screenshot pixels to display points ourselves.
                let labeledImages = screenCaptures.map { capture in
                    let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                    return (data: capture.imageData, label: capture.label + dimensionInfo)
                }

                // Pass conversation history so Claude remembers prior exchanges
                let historyForAPI = conversationHistory.map { entry in
                    (userPlaceholder: entry.userTranscript, assistantResponse: entry.assistantResponse)
                }

                let (fullResponseText, _) = try await claudeAgentSDK.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt(agentMode: isAgentModeEnabled),
                    conversationHistory: historyForAPI,
                    userPrompt: transcript,
                    // Stream speech: sentence-by-sentence as Claude responds,
                    // instead of waiting for the full response.
                    onTextChunk: { [weak self] chunk in
                        guard let self = self else { return }
                        let wasEmpty = self.displayedResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        self.displayedResponseText += chunk
                        let stripped = self.displayedResponseText
                            .replacingOccurrences(of: #"\[POINT:[^\]]*\]"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: #"\[POINT:[^\]]*$"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: #"\[RUN:[^\]]*\]"#, with: "", options: .regularExpression)
                            .replacingOccurrences(of: #"\[RUN:[^\]]*$"#, with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !stripped.isEmpty {
                            if wasEmpty {
                                self.responseOverlay.showOverlayAndBeginStreaming()
                            }
                            self.responseOverlay.updateStreamingText(stripped)
                        }
                        self.handleStreamedTextChunk(chunk)
                    }
                )

                guard !Task.isCancelled else { return }

                // Strip [RUN:...] before [POINT:...] so neither tag survives into spokenText/History.
                let runParseBeforePoint = Self.parseRunCommand(from: fullResponseText)
                let parseResult = Self.parsePointingCoordinates(from: runParseBeforePoint.spokenText)
                let runParseAfterPoint = Self.parseRunCommand(from: parseResult.spokenText)
                let parsedRunCommand = runParseBeforePoint.command ?? runParseAfterPoint.command
                let spokenText = runParseAfterPoint.spokenText

                // Handle element pointing if Claude returned coordinates.
                // Switch to idle BEFORE setting the location so the triangle
                // becomes visible and can fly to the target. Without this, the
                // spinner hides the triangle and the flight animation is invisible.
                let hasPointCoordinate = parseResult.coordinate != nil
                if hasPointCoordinate {
                    voiceState = .idle
                }

                // Pick the screen capture matching Claude's screen number,
                // falling back to the cursor screen if not specified.
                let targetScreenCapture: CompanionScreenCapture? = {
                    if let screenNumber = parseResult.screenNumber,
                       screenNumber >= 1 && screenNumber <= screenCaptures.count {
                        return screenCaptures[screenNumber - 1]
                    }
                    return screenCaptures.first(where: { $0.isCursorScreen })
                }()

                if let pointCoordinate = parseResult.coordinate,
                   let targetScreenCapture {
                    // Claude's coordinates are in the screenshot's pixel space
                    // (top-left origin, e.g. 1280x831). Scale to the display's
                    // point space (e.g. 1512x982), then convert to AppKit global coords.
                    let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
                    let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
                    let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
                    let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
                    let displayFrame = targetScreenCapture.displayFrame

                    // Clamp to screenshot coordinate space
                    let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                    let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

                    // Scale from screenshot pixels to display points
                    let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                    let displayLocalY = clampedY * (displayHeight / screenshotHeight)

                    // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
                    let appKitY = displayHeight - displayLocalY

                    // Convert display-local coords to global screen coords
                    let globalLocation = CGPoint(
                        x: displayLocalX + displayFrame.origin.x,
                        y: appKitY + displayFrame.origin.y
                    )

                    responseOverlay.hideOverlay()
                    detectedElementScreenLocation = globalLocation
                    detectedElementDisplayFrame = displayFrame
                    ClickyAnalytics.trackElementPointed(elementLabel: parseResult.elementLabel)
                    print("🎯 Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
                } else {
                    print("🎯 Element pointing: \(parseResult.elementLabel ?? "no element")")
                }

                if isAgentModeEnabled, let command = parsedRunCommand {
                    while ttsIsPlaying { try? await Task.sleep(nanoseconds: 200_000_000) }
                    if !Task.isCancelled {
                        if AgentCommandRunner.askUserToApprove(command: command) {
                            let output = await AgentCommandRunner.run(command: command)
                            conversationHistory.append((userTranscript: "(ran: \(command))", assistantResponse: output))
                            enqueueSpokenSentence("done")
                        } else {
                            enqueueSpokenSentence("okay, skipped it")
                        }
                    }
                }

                // Save this exchange to conversation history (with the point tag
                // stripped so it doesn't confuse future context)
                conversationHistory.append((
                    userTranscript: transcript,
                    assistantResponse: spokenText
                ))

                // Keep only the last 10 exchanges to avoid unbounded context growth
                if conversationHistory.count > 10 {
                    conversationHistory.removeFirst(conversationHistory.count - 10)
                }

                print("🧠 Conversation history: \(conversationHistory.count) exchanges")

                ClickyAnalytics.trackAIResponseReceived(response: spokenText)

                // Flush any remaining streamed speech (e.g. final sentence without
                // trailing punctuation) so nothing is lost.
                speechFlushTask?.cancel()
                if !streamedSpeechBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let finalChunk = streamedSpeechBuffer.replacingOccurrences(of: #"\[POINT:[^\]]*\]"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\[POINT:[^\]]*$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\[RUN:[^\]]*\]"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\[RUN:[^\]]*$"#, with: "", options: .regularExpression)
                    streamedSpeechBuffer = ""
                    enqueueSpokenSentence(finalChunk)
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                responseOverlay.hideOverlay()
            } catch {
                responseOverlay.hideOverlay()
                ClickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Companion response error: \(error)")
                speakCreditsErrorFallback()
            }

            if !Task.isCancelled {
                while ttsIsPlaying {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard !Task.isCancelled else { return }
                }
                voiceState = .idle
                responseOverlay.finishStreaming()
                scheduleTransientHideIfNeeded()
            }
        }
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for TTS playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for TTS audio to finish playing
            while ttsIsPlaying {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    /// Speaks a hardcoded error message using macOS system TTS when API
    /// credits run out. Uses NSSpeechSynthesizer so it works even when
    /// the TTS service is down.
    private func speakCreditsErrorFallback() {
        let utterance = "I'm all out of credits. Please DM Farza and tell him to bring me back to life."
        let synthesizer = NSSpeechSynthesizer()
        synthesizer.startSpeaking(utterance)
        voiceState = .responding
    }

    // MARK: - Point Tag Parsing

    /// Parses a [RUN:command] tag from the end of Claude's response.
    static func parseRunCommand(from responseText: String) -> (spokenText: String, command: String?) {
        let pattern = #"\[RUN:([^\]]+)\]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            return (responseText, nil)
        }
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let commandRange = Range(match.range(at: 1), in: responseText)!
        return (spokenText, String(responseText[commandRange]))
    }

    /// Result of parsing a [POINT:...] tag from Claude's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Claude said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Claude's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Video

    /// Sets up the onboarding video player, starts playback, and schedules
    /// the demo interaction at 40s. Called by BlueCursorView when onboarding starts.
    func setupOnboardingVideo() {
        guard let videoURL = URL(string: "https://stream.mux.com/e5jB8UuSrtFABVnTHCR7k3sIsmcUHCyhtLu1tzqLlfs.m3u8") else { return }

        let player = AVPlayer(url: videoURL)
        player.isMuted = false
        player.volume = 0.0
        self.onboardingVideoPlayer = player
        self.showOnboardingVideo = true
        self.onboardingVideoOpacity = 0.0

        // Start playback immediately — the video plays while invisible,
        // then we fade in both the visual and audio over 1s.
        player.play()

        // Wait for SwiftUI to mount the view, then set opacity to 1.
        // The .animation modifier on the view handles the actual animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.onboardingVideoOpacity = 1.0
            // Fade audio volume from 0 → 1 over 2s to match visual fade
            self.fadeInVideoAudio(player: player, targetVolume: 1.0, duration: 2.0)
        }

        // At 40 seconds into the video, trigger the onboarding demo where
        // Clicky flies to something interesting on screen and comments on it
        let demoTriggerTime = CMTime(seconds: 40, preferredTimescale: 600)
        onboardingDemoTimeObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: demoTriggerTime)],
            queue: .main
        ) { [weak self] in
            ClickyAnalytics.trackOnboardingDemoTriggered()
            self?.performOnboardingDemoInteraction()
        }

        // Fade out and clean up when the video finishes
        onboardingVideoEndObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            ClickyAnalytics.trackOnboardingVideoCompleted()
            self.onboardingVideoOpacity = 0.0
            // Wait for the 2s fade-out animation to complete before tearing down
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                self.tearDownOnboardingVideo()
                // After the video disappears, stream in the prompt to try talking
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.startOnboardingPromptStream()
                }
            }
        }
    }

    func tearDownOnboardingVideo() {
        showOnboardingVideo = false
        if let timeObserver = onboardingDemoTimeObserver {
            onboardingVideoPlayer?.removeTimeObserver(timeObserver)
            onboardingDemoTimeObserver = nil
        }
        onboardingVideoPlayer?.pause()
        onboardingVideoPlayer = nil
        if let observer = onboardingVideoEndObserver {
            NotificationCenter.default.removeObserver(observer)
            onboardingVideoEndObserver = nil
        }
    }

    private func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }

    /// Gradually raises an AVPlayer's volume from its current level to the
    /// target over the specified duration, creating a smooth audio fade-in.
    private func fadeInVideoAudio(player: AVPlayer, targetVolume: Float, duration: Double) {
        let steps = 20
        let stepInterval = duration / Double(steps)
        let volumeIncrement = (targetVolume - player.volume) / Float(steps)
        var stepsRemaining = steps

        Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { timer in
            stepsRemaining -= 1
            player.volume += volumeIncrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.volume = targetVolume
            }
        }
    }

    // MARK: - Onboarding Demo Interaction

    private static let onboardingDemoSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. you're showing off during onboarding — look at their screen and find ONE specific, concrete thing to point at. pick something with a clear name or identity: a specific app icon (say its name), a specific word or phrase of text you can read, a specific filename, a specific button label, a specific tab title, a specific image you can describe. do NOT point at vague things like "a window" or "some text" — be specific about exactly what you see.

    make a short quirky 3-6 word observation about the specific thing you picked — something fun, playful, or curious that shows you actually read/recognized it. no emojis ever. NEVER quote or repeat text you see on screen — just react to it. keep it to 6 words max, no exceptions.

    CRITICAL COORDINATE RULE: you MUST only pick elements near the CENTER of the screen. your x coordinate must be between 20%-80% of the image width. your y coordinate must be between 20%-80% of the image height. do NOT pick anything in the top 20%, bottom 20%, left 20%, or right 20% of the screen. no menu bar items, no dock icons, no sidebar items, no items near any edge. only things clearly in the middle area of the screen. if the only interesting things are near the edges, pick something boring in the center instead.

    respond with ONLY your short comment followed by the coordinate tag. nothing else. all lowercase.

    format: your comment [POINT:x,y:label]

    the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. origin (0,0) is top-left. x increases rightward, y increases downward.
    """

    /// Captures a screenshot and asks Claude to find something interesting to
    /// point at, then triggers the buddy's flight animation. Used during
    /// onboarding to demo the pointing feature while the intro video plays.
    func performOnboardingDemoInteraction() {
        // Don't interrupt an active voice response
        guard voiceState == .idle || voiceState == .responding else { return }

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()

                // Only send the cursor screen so Claude can't pick something
                // on a different monitor that we can't point at.
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    print("🎯 Onboarding demo: no cursor screen found")
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await claudeAgentSDK.analyzeImageStreaming(
                    images: labeledImages,
                    systemPrompt: Self.onboardingDemoSystemPrompt,
                    userPrompt: "look around my screen and find something interesting to point at",
                    onTextChunk: { _ in }
                )

                let parseResult = Self.parsePointingCoordinates(from: fullResponseText)

                guard let pointCoordinate = parseResult.coordinate else {
                    print("🎯 Onboarding demo: no element to point at")
                    return
                }

                let screenshotWidth = CGFloat(cursorScreenCapture.screenshotWidthInPixels)
                let screenshotHeight = CGFloat(cursorScreenCapture.screenshotHeightInPixels)
                let displayWidth = CGFloat(cursorScreenCapture.displayWidthInPoints)
                let displayHeight = CGFloat(cursorScreenCapture.displayHeightInPoints)
                let displayFrame = cursorScreenCapture.displayFrame

                let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
                let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))
                let displayLocalX = clampedX * (displayWidth / screenshotWidth)
                let displayLocalY = clampedY * (displayHeight / screenshotHeight)
                let appKitY = displayHeight - displayLocalY
                let globalLocation = CGPoint(
                    x: displayLocalX + displayFrame.origin.x,
                    y: appKitY + displayFrame.origin.y
                )

                // Set custom bubble text so the pointing animation uses Claude's
                // comment instead of a random phrase
                detectedElementBubbleText = parseResult.spokenText
                detectedElementScreenLocation = globalLocation
                detectedElementDisplayFrame = displayFrame
                print("🎯 Onboarding demo: pointing at \"\(parseResult.elementLabel ?? "element")\" — \"\(parseResult.spokenText)\"")
            } catch {
                print("⚠️ Onboarding demo error: \(error)")
            }
        }
    }
}
