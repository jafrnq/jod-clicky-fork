import Foundation
import AppKit

@MainActor
enum CodexAccountStatus {
    case ready(plan: String)
    case signingIn
    case notAuthenticated
    case notInstalled
    case failed(message: String)
}

@MainActor
final class CodexAgentSDKAPI: AgentBackend {
    private let processManager = CodexProcessManager()
    private var threadId: String?
    private var resolvedModelId: String = "gpt-5.4-mini"
    private var resolvedReasoningEffort: String = "high"
    private var isStarted = false

    /// Called after app-server reports that a browser sign-in changed the account.
    /// The panel owns presentation state, so the SDK only reports the new status.
    var onAccountStatusChanged: (@MainActor (CodexAccountStatus) -> Void)?

    func applyConfiguration(model: String, reasoningEffort: String) {
        self.resolvedModelId = model
        self.resolvedReasoningEffort = reasoningEffort
    }

    func listAvailableModels() async throws -> [AgentModelOption] {
        try ensureStarted()
        var allModels: [AgentModelOption] = []
        var nextCursor: String? = nil
        repeat {
            var params: [String: Any] = ["includeHidden": false]
            if let cursor = nextCursor { params["nextCursor"] = cursor }
            let res = try await processManager.sendRequest(method: "model/list", params: params)
            if let items = res["items"] as? [[String: Any]] {
                for item in items {
                    guard let id = item["id"] as? String,
                          let displayName = item["displayName"] as? String,
                          let defaultEffort = item["defaultReasoningEffort"] as? String,
                          let supported = item["supportedReasoningEfforts"] as? [[String: Any]] else { continue }
                    let isDefault = item["isDefault"] as? Bool ?? false
                    let efforts = supported.compactMap { dict -> AgentReasoningOption? in
                        guard let eff = dict["reasoningEffort"] as? String else { return nil }
                        return AgentReasoningOption(value: eff, displayName: eff.prefix(1).uppercased() + eff.dropFirst())
                    }
                    allModels.append(AgentModelOption(id: id, displayName: displayName, isDefault: isDefault, supportedReasoningEfforts: efforts, defaultReasoningEffort: defaultEffort))
                }
            }
            nextCursor = res["nextCursor"] as? String
        } while nextCursor != nil
        return allModels
    }

    func readAccountStatus() async -> CodexAccountStatus {
        do {
            try ensureStarted()
            let res = try await processManager.sendRequest(method: "account/read", params: [:])
            return Self.accountStatus(from: res)
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == "CodexProcess" && nsErr.code == 1 {
                return .notInstalled
            }
            return .failed(message: nsErr.localizedDescription)
        }
    }

    /// Decodes account/read without treating the advisory requiresOpenaiAuth
    /// field as stronger evidence than a returned ChatGPT account.
    static func accountStatus(from response: [String: Any]) -> CodexAccountStatus {
        if let account = response["account"] as? [String: Any],
           let accountType = account["type"] as? String,
           accountType == "chatgpt" {
            return .ready(plan: account["planType"] as? String ?? "unknown")
        }
        return .notAuthenticated
    }

    /// Starts Codex's supported ChatGPT browser sign-in and leaves credentials
    /// in Pauline V6's isolated CODEX_HOME rather than borrowing V5's auth file.
    func startChatGPTLogin() async -> CodexAccountStatus {
        do {
            try ensureStarted()
            let response = try await processManager.sendRequest(
                method: "account/login/start",
                params: ["type": "chatgpt", "useHostedLoginSuccessPage": true]
            )
            guard let authURLString = response["authUrl"] as? String,
                  let authURL = URL(string: authURLString) else {
                return .failed(message: "Codex did not provide a ChatGPT sign-in link.")
            }
            NSWorkspace.shared.open(authURL)
            return .signingIn
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    func logout() async -> CodexAccountStatus {
        do {
            try ensureStarted()
            _ = try await processManager.sendRequest(method: "account/logout", params: [:])
            threadId = nil
            return .notAuthenticated
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
    
    func shutdown() {
        processManager.stop()
        isStarted = false
    }
    
    var model: String {
        get { UserDefaults.standard.string(forKey: "codexModel") ?? "gpt-5.4-mini" }
        set { UserDefaults.standard.set(newValue, forKey: "codexModel") }
    }
    
    var agentModeEnabled: Bool = false
    var maxOutputTokens: Int = 4096
    
    private var currentTextChunkHandler: (@MainActor @Sendable (String) -> Void)?
    private var activeTurnContinuation: CheckedContinuation<(text: String, duration: TimeInterval), Error>?
    private var turnId: String?
    private var accumulatedOutput = ""
    private var turnStartTime: Date?
    private var timeoutTask: Task<Void, Never>?
    
    init() {
        processManager.onNotification = { [weak self] json in
            Task { @MainActor [weak self] in
                self?.handleNotification(json)
            }
        }
    }
    
    private func handleNotification(_ json: [String: Any]) {
        guard let method = json["method"] as? String else { return }
        
        let params = json["params"] as? [String: Any] ?? [:]
        
        if method == "account/login/completed" || method == "account/updated" {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.onAccountStatusChanged?(await self.readAccountStatus())
            }
        } else if method == "item/agentMessage/delta", let text = params["delta"] as? String {
            accumulatedOutput += text
            currentTextChunkHandler?(text)
        } else if method == "item/commandExecution/outputDelta", let text = params["delta"] as? String {
            let wrapped = "\n```\n\(text)\n```\n"
            accumulatedOutput += wrapped
            currentTextChunkHandler?(wrapped)
        } else if method == "command/exec/outputDelta", let text = params["text"] as? String {
            let wrapped = "\n```\n\(text)\n```\n"
            accumulatedOutput += wrapped
            currentTextChunkHandler?(wrapped)
        } else if method == "turn/completed" || method == "turn/complete" {
            // Check if it's for our turn
            if let tId = params["turnId"] as? String, tId != turnId && turnId != nil {
                return
            }
            finishTurn()
        }
    }
    
    private func finishTurn(error: Error? = nil) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let duration = Date().timeIntervalSince(turnStartTime ?? Date())
        if let err = error {
            activeTurnContinuation?.resume(throwing: err)
        } else {
            activeTurnContinuation?.resume(returning: (text: accumulatedOutput, duration: duration))
        }
        activeTurnContinuation = nil
        currentTextChunkHandler = nil
    }
    
    func warmUp(systemPrompt: String) {
        Task {
            try? ensureStarted()
        }
    }

    private func ensureStarted() throws {
        guard !isStarted else { return }
        try processManager.start(
            model: resolvedModelId,
            sandboxMode: agentModeEnabled ? "danger-full-access" : "workspace-write",
            reasoningEffort: resolvedReasoningEffort
        )
        isStarted = true
    }
    
    func stop() {
        if let thId = threadId, let tuId = turnId {
            Task { try? await processManager.sendRequest(method: "turn/interrupt", params: ["threadId": thId, "turnId": tuId]) }
        }
        finishTurn(error: CancellationError())
    }
    
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        turnStartTime = Date()
        currentTextChunkHandler = onTextChunk
        accumulatedOutput = ""
        
        if threadId == nil {
            let threadRes = try await processManager.sendRequest(method: "thread/start", params: [
                "model": resolvedModelId,
                "cwd": NSHomeDirectory(),
                "developerInstructions": systemPrompt,
                "sandbox": agentModeEnabled ? "danger-full-access" : "workspace-write"
            ])
            guard let tId = threadRes["threadId"] as? String else {
                throw NSError(domain: "CodexAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "No threadId"])
            }
            self.threadId = tId
        }
        guard let threadId = self.threadId else { return ("", 0) }
        
        var inputText = userPrompt
        for msg in conversationHistory {
            inputText = "user: \(msg.userPlaceholder)\nassistant: \(msg.assistantResponse)\n" + inputText
        }
        
        var inputList: [[String: Any]] = [["type": "text", "text": inputText]]
        for image in images {
            inputList.append(["type": "image", "url": "data:image/jpeg;base64,\(image.data.base64EncodedString())"])
        }
        var turnParams: [String: Any] = [
            "threadId": threadId,
            "effort": resolvedReasoningEffort,
            "input": inputList
        ]
        
        let turnRes = try await processManager.sendRequest(method: "turn/start", params: turnParams)
        self.turnId = turnRes["turnId"] as? String
        
        return try await withCheckedThrowingContinuation { continuation in
            self.activeTurnContinuation = continuation
            
            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finishTurn(error: NSError(domain: "CodexAPI", code: -40, userInfo: [NSLocalizedDescriptionKey: "Turn timeout"]))
            }
        }
    }
}
