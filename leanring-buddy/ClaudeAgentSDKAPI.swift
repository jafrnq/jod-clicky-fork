//
//  ClaudeAgentSDKAPI.swift
//  OpenClicky
//
//  Local Claude Agent SDK bridge. This keeps one Claude Agent SDK query session
//  warm and streams each voice turn through that session instead of spawning a
//  fresh Claude process for every response.
//

import Darwin
import Foundation

@MainActor
final class ClaudeAgentSDKAPI: AgentBackend {
    private typealias ResponseContinuation = CheckedContinuation<(text: String, duration: TimeInterval), Error>

    private struct PendingRequest {
        let id: String
        let startedAt: Date
        let onTextChunk: @MainActor @Sendable (String) -> Void
        let continuation: ResponseContinuation
        var timeoutTask: Task<Void, Never>?
        var accumulatedText: String
        var didReceiveFirstDelta: Bool
    }

    private let executableURL: URL?
    private let nodeExecutableURL: URL?
    private let bridgeScriptURL: URL?
    private let fileManager: FileManager
    private let workingDirectory: URL
    var model: String
    var maxOutputTokens: Int
    var agentModeEnabled: Bool = false

    /// Claude Agent SDK reasoning effort: low|medium|high|xhigh|max.
    var reasoningEffort: String = "high"

    private static func persistentBridgeSystemPrompt(agentMode: Bool) -> String {
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
            base += """
        - you can look things up on the web, and you can actually operate this mac.
        - to do anything in an app: use the computer-use tools. get_window_state first, then click / type_text / set_value / press_key on the element you found, then verify_state. they run in the background — never front an app, never move the user's cursor.
        - to open an app: launch_app with its name or bundle id. never shell `open -a`, never osascript, never cmd-tab. launch_app keeps it in the background.
        - [RUN:cmd] is only for genuinely shell-only work — git, npm, a script. never for opening apps or clicking UI. one RUN tag max.
        - say in one short sentence what you're doing, do it, then say it's done.
        - act on what they asked for. their instruction is the approval — don't re-ask, don't draft and wait.
        - confirm FIRST, and only for these: deleting or archiving data, overwriting content they didn't ask you to replace, sending a message or email, or spending money. say the one-line confirm out loud and end your reply with [ASK:send the email to ada?]. one ASK tag max. everything else: just do it and say what you did.
"""
        } else {
            base += "\n        - you cannot run commands, click, launch apps, or change anything on this machine. you only look and talk. never say what you \"can\" or \"can't\" do for them — describe and advise. if you can't see something, say you can't see it, don't conclude it isn't installed.\n"
        }
        return base
    }

    private var bridgeProcess: Process?
    private var bridgeInput: FileHandle?
    private var bridgeOutput: FileHandle?
    private var bridgeError: FileHandle?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var pendingRequests: [String: PendingRequest] = [:]
    private var warmupRequestID: String?
    private var activeBridgeModel: String?
    private var activeBridgeConfigurationHash: Int?
    private var activeBridgeProviderFingerprint: Int?
    // Allows a cold bridge to start normally while ensuring a wedged SDK
    // request cannot leave the voice lane suspended forever.
    private static let requestTimeoutNanoseconds: UInt64 = 120_000_000_000

    init(
        model: String = "claude-sonnet-4-6",
        maxOutputTokens: Int = 180,
        fileManager: FileManager = .default,
        workingDirectory: URL? = nil
    ) {
        self.executableURL = Self.findExecutable(fileManager: fileManager)
        self.nodeExecutableURL = Self.findNodeExecutable(fileManager: fileManager)
        self.bridgeScriptURL = Self.findBridgeScript(fileManager: fileManager)
        self.fileManager = fileManager
        self.workingDirectory = workingDirectory ?? fileManager.homeDirectoryForCurrentUser
        self.model = model
        self.maxOutputTokens = maxOutputTokens
    }

    deinit {
        bridgeProcess?.terminationHandler = nil
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        try? bridgeInput?.close()
        terminateBridgeProcess(bridgeProcess)
    }

    static func findExecutable(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["OPENCLICKY_CLAUDE_EXECUTABLE"],
           let executable = executableURL(atPath: explicitPath, fileManager: fileManager) {
            return executable
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("claude", isDirectory: false) }

        // Canonical native-install locations are checked before a raw PATH scan.
        // Third-party tools (terminal wrappers, IDE-bundled copies, etc.) commonly
        // prepend their own bin directory onto PATH ahead of the real install;
        // their `claude` is often a thin shim built for interactive terminal use
        // and can misbehave when driven through the SDK's non-interactive
        // stdin/stdout protocol. Prefer the user's actual Claude Code install.
        let fixedCandidates = [
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/claude", isDirectory: false)
        ]

        return (fixedCandidates + pathCandidates).first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    /// Prefers the app bundle binary; the ~/.local/bin symlink is the fallback.
    static func findCuaDriverExecutable(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/CuaDriver.app/Contents/MacOS/cua-driver", isDirectory: false),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cua-driver", isDirectory: false)
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    static func findNodeExecutable(fileManager: FileManager = .default) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let explicitPath = environment["OPENCLICKY_NODE_EXECUTABLE"],
           let executable = executableURL(atPath: explicitPath, fileManager: fileManager) {
            return executable
        }

        var candidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("node", isDirectory: false) }

        let home = fileManager.homeDirectoryForCurrentUser
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/node", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/node", isDirectory: false),
            URL(fileURLWithPath: "/usr/bin/node", isDirectory: false)
        ])

        let nvmRoot = home
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: versions
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
                .map { $0.appendingPathComponent("bin/node", isDirectory: false) })
        }

        return candidates.first { candidate in
            fileManager.isExecutableFile(atPath: candidate.path)
        }
    }

    func warmUp(systemPrompt: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.sendRequest(
                    kind: "warmup",
                    images: [],
                    systemPrompt: systemPrompt,
                    conversationHistory: [],
                    userPrompt: "get ready. prime the OpenClicky voice response session and reply with ready only.",
                    onTextChunk: { _ in }
                )
            } catch is CancellationError {
                return
            } catch {
            }
        }
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        // M16: optional assistant prefill, forwarded to the bridge so the SDK
        // (primary) path behaves like the HTTP fallback. Previously prefill was
        // silently dropped on the SDK path, causing quality divergence.
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try await sendRequest(
            kind: "request",
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            assistantPrefill: assistantPrefill,
            onTextChunk: onTextChunk
        )
    }

    func stop() {
        stopBridge(failingPendingRequestsWith: CancellationError())
    }

    private func stopBridge(failingPendingRequestsWith error: Error) {
        let process = bridgeProcess
        bridgeProcess = nil
        process?.terminationHandler = nil
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        try? bridgeInput?.close()
        bridgeInput = nil
        bridgeOutput = nil
        bridgeError = nil
        activeBridgeModel = nil
        activeBridgeConfigurationHash = nil
        terminateBridgeProcess(process)
        failPendingRequests(error)
    }

    private func sendRequest(
        kind: String,
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        assistantPrefill: String? = nil,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        try ensureBridge()
        try Task.checkCancellation()

        let requestID = UUID().uuidString
        let attachments = images.map { image -> [String: Any] in
            [
                "label": image.label,
                "mediaType": image.data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg",
                "data": image.data.base64EncodedString()
            ]
        }
        let history = conversationHistory.map { entry -> [String: Any] in
            [
                "user": entry.userPlaceholder,
                "assistant": entry.assistantResponse
            ]
        }
        var payload: [String: Any] = [
            "type": kind,
            "id": requestID,
            "systemPrompt": systemPrompt,
            "prompt": userPrompt,
            "conversationHistory": history,
            "images": attachments
        ]
        // M16: forward prefill to the bridge when provided so the SDK path can
        // seed the assistant turn like the HTTP fallback does.
        if let assistantPrefill, !assistantPrefill.isEmpty {
            payload["assistantPrefill"] = assistantPrefill
        }


        return try await withTaskCancellationHandler(operation: { [weak self] in
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.pendingRequests[requestID] = PendingRequest(
                    id: requestID,
                    startedAt: Date(),
                    onTextChunk: onTextChunk,
                    continuation: continuation,
                    timeoutTask: nil,
                    accumulatedText: "",
                    didReceiveFirstDelta: false
                )
                if kind == "warmup" {
                    self.warmupRequestID = requestID
                }
                self.scheduleTimeout(for: requestID)

                do {
                    try self.writeBridgeCommand(payload)
                } catch {
                    self.failRequestIfPending(requestID: requestID, error: error)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelRequestIfPending(requestID: requestID)
            }
        })
    }

    /// Fingerprints the configured Anthropic-compatible provider (base URL + a
    /// hash of the key, never the key itself) so a live persistent bridge is
    /// torn down and respawned if the user reconfigures the provider (e.g.
    /// switches from one Anthropic-compatible endpoint to another) instead of
    /// silently keeping the old provider's environment for the life of the
    /// warm subprocess.
    private static func currentProviderFingerprint() -> Int {
        var hasher = Hasher()
        return hasher.finalize()
    }

    private func ensureBridge() throws {
        var hasher = Hasher()
        hasher.combine(Self.persistentBridgeSystemPrompt(agentMode: agentModeEnabled))
        hasher.combine(agentModeEnabled)
        hasher.combine(reasoningEffort)
        hasher.combine(maxOutputTokens)
        hasher.combine(Self.findCuaDriverExecutable(fileManager: fileManager)?.path ?? "")
        let configHash = hasher.finalize()

        if let bridgeProcess,
           bridgeProcess.isRunning,
           activeBridgeModel == model,
           activeBridgeConfigurationHash == configHash,
           bridgeInput != nil {
            return
        }

        stopBridge(
            failingPendingRequestsWith: NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK bridge was reset for a new configuration."]
            )
        )

        guard let executableURL else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -23,
                userInfo: [NSLocalizedDescriptionKey: "Could not locate /usr/bin/env."]
            )
        }
        guard let nodeExecutableURL else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "Node.js is required for the Claude Agent SDK bridge but was not found."]
            )
        }

        guard let bridgeScriptURL else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -21,
                userInfo: [NSLocalizedDescriptionKey: "OpenClicky could not find ClaudeAgentSDKBridge/bridge.mjs."]
            )
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = nodeExecutableURL
        process.arguments = [bridgeScriptURL.path]
        process.currentDirectoryURL = workingDirectory
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = bridgeEnvironment(
            nodeExecutableURL: nodeExecutableURL,
            bridgeScriptURL: bridgeScriptURL,
            systemPrompt: Self.persistentBridgeSystemPrompt(agentMode: agentModeEnabled)
        )

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeStdout(text)
            }
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.consumeStderr(text)
            }
        }

        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleBridgeTermination(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        bridgeProcess = process
        bridgeInput = inputPipe.fileHandleForWriting
        bridgeOutput = outputPipe.fileHandleForReading
        bridgeError = errorPipe.fileHandleForReading
        activeBridgeModel = model
        activeBridgeConfigurationHash = configHash

    }

    private func bridgeEnvironment(
        nodeExecutableURL: URL,
        bridgeScriptURL: URL,
        systemPrompt: String
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let nodeDirectory = nodeExecutableURL.deletingLastPathComponent().path
        let existingPath = environment["PATH"] ?? ""
        let baselinePath = "\(fileManager.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [nodeDirectory, existingPath, baselinePath]
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        environment["OPENCLICKY_CLAUDE_EXECUTABLE"] = executableURL?.path
        environment["OPENCLICKY_CLAUDE_MODEL"] = model
        environment["OPENCLICKY_CLAUDE_EFFORT"] = reasoningEffort
        environment["OPENCLICKY_CLAUDE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(maxOutputTokens)
        environment["OPENCLICKY_CLAUDE_CWD"] = workingDirectory.path
        environment["OPENCLICKY_CLAUDE_SYSTEM_PROMPT"] = systemPrompt
        environment["OPENCLICKY_CLAUDE_AGENT_SDK_PATHS"] = Self.nodeModuleSearchPaths(
            bridgeScriptURL: bridgeScriptURL,
            fileManager: fileManager
        ).joined(separator: ":")
        environment["CLAUDE_AGENT_SDK_CLIENT_APP"] = "openclicky/1.0"
        
        let computerUseTools = [
            "mcp__cua__list_apps", "mcp__cua__list_windows", "mcp__cua__launch_app",
            "mcp__cua__get_window_state", "mcp__cua__click", "mcp__cua__double_click",
            "mcp__cua__type_text", "mcp__cua__set_value", "mcp__cua__press_key",
            "mcp__cua__hotkey", "mcp__cua__scroll", "mcp__cua__invoke_menu",
            "mcp__cua__verify_state", "mcp__cua__zoom"
        ]
        let cuaDriverExecutableURL = agentModeEnabled ? Self.findCuaDriverExecutable(fileManager: fileManager) : nil
        environment["OPENCLICKY_CLAUDE_ALLOWED_TOOLS"] = agentModeEnabled
            ? (["WebSearch", "WebFetch", "Read"] + (cuaDriverExecutableURL == nil ? [] : computerUseTools)).joined(separator: ",")
            : ""
        if let cuaDriverExecutableURL {
            environment["OPENCLICKY_CUA_DRIVER_PATH"] = cuaDriverExecutableURL.path
        } else {
            environment.removeValue(forKey: "OPENCLICKY_CUA_DRIVER_PATH")
        }
        
        environment["OPENCLICKY_CLAUDE_PERMISSION_MODE"] = "default" // acceptEdits auto-approves Write/Edit even when absent from allowedTools

        // Force this child process onto OpenClicky's configured Anthropic-compatible
        // provider (e.g. MiniMax via ANTHROPIC_BASE_URL in secrets.env), overriding
        // any ANTHROPIC_API_KEY/ANTHROPIC_AUTH_TOKEN or logged-in `claude` session
        // that may already exist in the surrounding OS environment. This only
        // affects this one subprocess — it does not touch the user's own
        // interactive `claude` CLI sessions or their ~/.claude credentials.
        environment.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        environment.removeValue(forKey: "ANTHROPIC_BASE_URL")
        environment.removeValue(forKey: "ANTHROPIC_API_KEY")

        return environment
    }

    private static func nodeModuleSearchPaths(bridgeScriptURL: URL, fileManager: FileManager) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        var paths = [
            bridgeScriptURL.deletingLastPathComponent().path,
            home.appendingPathComponent(".nvm/versions/node", isDirectory: true).path,
            "/opt/homebrew/lib/node_modules",
            "/usr/local/lib/node_modules"
        ]

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            paths.append(contentsOf: versions.map {
                $0.appendingPathComponent("lib/node_modules", isDirectory: true).path
            })
        }

        return Array(Set(paths)).sorted()
    }

    private func writeBridgeCommand(_ command: [String: Any]) throws {
        guard let bridgeInput else {
            throw NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK bridge input is not available."]
            )
        }

        let data = try JSONSerialization.data(withJSONObject: command)
        bridgeInput.write(data)
        bridgeInput.write(Data("\n".utf8))
    }

    private func consumeStdout(_ text: String) {
        stdoutBuffer += text
        let lines = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            handleBridgeLine(line)
        }
    }

    private func consumeStderr(_ text: String) {
        stderrBuffer += text
        let lines = stderrBuffer.components(separatedBy: "\n")
        stderrBuffer = lines.last ?? ""
        for line in lines.dropLast() where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        }
    }

    private func handleBridgeLine(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        let requestID = event["id"] as? String
        switch type {
        case "ready":
            break
        case "started":
            break
        case "delta":
            guard let requestID,
                  var pending = pendingRequests[requestID],
                  let text = event["text"] as? String else { return }
            pending.accumulatedText += text
            if !pending.didReceiveFirstDelta {
                pending.didReceiveFirstDelta = true
            }
            pendingRequests[requestID] = pending
            pending.onTextChunk(text)

        case "result":
            guard let requestID,
                  let pending = pendingRequests.removeValue(forKey: requestID) else { return }
            pending.timeoutTask?.cancel()
            let text = (event["text"] as? String) ?? pending.accumulatedText
            let duration = Date().timeIntervalSince(pending.startedAt)
            let logEvent = requestID == warmupRequestID ? "claude_agent_sdk.warmup.ready" : "claude_agent_sdk.query.response"
            if requestID == warmupRequestID {
                warmupRequestID = nil
            }
            pending.continuation.resume(returning: (text: text, duration: duration))

        case "error":
            let message = (event["message"] as? String) ?? "Claude Agent SDK bridge error."
            let error = NSError(
                domain: "ClaudeAgentSDKAPI",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            if let requestID,
               let pending = pendingRequests.removeValue(forKey: requestID) {
                pending.timeoutTask?.cancel()
                if requestID == warmupRequestID { warmupRequestID = nil }
                pending.continuation.resume(throwing: error)
            } else {
                failPendingRequests(error)
            }

        default:
            break
        }
    }

    private func handleBridgeTermination(status: Int32) {
        bridgeOutput?.readabilityHandler = nil
        bridgeError?.readabilityHandler = nil
        bridgeProcess = nil
        bridgeInput = nil
        bridgeOutput = nil
        bridgeError = nil
        activeBridgeModel = nil
        activeBridgeConfigurationHash = nil

        let error = NSError(
            domain: "ClaudeAgentSDKAPI",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK bridge exited with status \(status)."]
        )
        failPendingRequests(error)
    }

    private func scheduleTimeout(for requestID: String) {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.requestTimeoutNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.failRequestIfPending(
                requestID: requestID,
                error: NSError(
                    domain: "ClaudeAgentSDKAPI",
                    code: -40,
                    userInfo: [NSLocalizedDescriptionKey: "Claude Agent SDK did not respond within two minutes."]
                ),
                tearDownBridge: true
            )
        }
        guard var pending = pendingRequests[requestID] else {
            timeoutTask.cancel()
            return
        }
        pending.timeoutTask = timeoutTask
        pendingRequests[requestID] = pending
    }

    private func cancelRequestIfPending(requestID: String) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        if requestID == warmupRequestID { warmupRequestID = nil }
        pending.continuation.resume(throwing: CancellationError())
        // The bridge protocol has no per-request abort command. Rebuild it
        // after interruption so a cancelled SDK query cannot emit a late
        // result into the next voice turn.
        stopBridge(failingPendingRequestsWith: CancellationError())
    }

    private func failRequestIfPending(requestID: String, error: Error, tearDownBridge: Bool = true) {
        guard let pending = pendingRequests.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        if requestID == warmupRequestID { warmupRequestID = nil }
        print("ClaudeAgentSDKAPI: request \(requestID) failed — \(error.localizedDescription)")
        pending.continuation.resume(throwing: error)
        if tearDownBridge {
            // A timed-out request leaves the bridge's state unknown. Tear it
            // down so the next call cannot inherit a stuck session.
            stopBridge(failingPendingRequestsWith: error)
        }
    }

    private func failPendingRequests(_ error: Error) {
        let requests = pendingRequests.values
        pendingRequests.removeAll()
        warmupRequestID = nil
        for request in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    nonisolated private func terminateBridgeProcess(_ process: Process?) {
        guard let process, process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            guard process.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    private static func executableURL(atPath path: String, fileManager: FileManager) -> URL? {
        let expandedPath = (path as NSString).expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: expandedPath) else { return nil }
        return URL(fileURLWithPath: expandedPath, isDirectory: false)
    }

    private static func findBridgeScript(fileManager: FileManager = .default) -> URL? {
        if let envPath = ProcessInfo.processInfo.environment["OPENCLICKY_CLAUDE_AGENT_BRIDGE"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envPath.isEmpty {
            return URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath, isDirectory: false)
        }
        return Bundle.main.url(forResource: "bridge", withExtension: "mjs")
    }

    private static func elapsedMilliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    private static func truncated(_ value: String, maxLength: Int) -> String {
        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength))
    }
}
