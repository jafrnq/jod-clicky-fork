//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test @MainActor func authenticatedChatGPTAccountWinsOverRequiresOpenAIAuthFlag() {
        let accountStatus = CodexAgentSDKAPI.accountStatus(from: [
            "requiresOpenaiAuth": true,
            "account": [
                "type": "chatgpt",
                "planType": "plus"
            ]
        ])

        guard case .ready(let plan) = accountStatus else {
            Issue.record("A signed-in ChatGPT account must be treated as authenticated.")
            return
        }
        #expect(plan == "plus")
    }

    @Test @MainActor func missingCodexAccountRequiresAuthentication() {
        let accountStatus = CodexAgentSDKAPI.accountStatus(from: [
            "requiresOpenaiAuth": true
        ])

        guard case .notAuthenticated = accountStatus else {
            Issue.record("An account response without a ChatGPT account must request sign-in.")
            return
        }
    }

    @Test @MainActor func currentCodexModelListResponsePopulatesThePicker() {
        let models = CodexAgentSDKAPI.modelOptions(from: [
            "data": [[
                "id": "gpt-5.6-sol",
                "displayName": "GPT-5.6-Sol",
                "defaultReasoningEffort": "low",
                "supportedReasoningEfforts": [["reasoningEffort": "low"]],
                "isDefault": true
            ]]
        ])

        #expect(models.count == 1)
        #expect(models.first?.id == "gpt-5.6-sol")
        #expect(models.first?.isDefault == true)
    }

    @Test @MainActor func currentCodexThreadAndTurnResponsesUseNestedIdentifiers() {
        let threadIdentifier = CodexAgentSDKAPI.threadIdentifier(from: [
            "thread": ["id": "thr_123"]
        ])
        let turnIdentifier = CodexAgentSDKAPI.turnIdentifier(from: [
            "turn": ["id": "turn_456"]
        ])

        #expect(threadIdentifier == "thr_123")
        #expect(turnIdentifier == "turn_456")
    }

    @Test @MainActor func codexThreadStartUsesRuntimeCompatibleSandboxValues() {
        #expect(CodexAgentSDKAPI.threadSandboxMode(agentModeEnabled: false) == "workspace-write")
        #expect(CodexAgentSDKAPI.threadSandboxMode(agentModeEnabled: true) == "danger-full-access")
    }

    @Test func edgeVoiceIdentifierIsNeverPassedToAppleSpeech() {
        #expect(AppleTTSClient.appleSpeechVoiceIdentifier(from: "edge:en-US-EmmaMultilingualNeural") == nil)
        #expect(AppleTTSClient.appleSpeechVoiceIdentifier(from: "com.apple.voice.compact.en-US.Samantha") == "com.apple.voice.compact.en-US.Samantha")
    }

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

}
