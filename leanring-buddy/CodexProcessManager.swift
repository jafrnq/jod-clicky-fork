import Foundation

class CodexProcessManager {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    
    private let queue = DispatchQueue(label: "CodexProcessManager")
    private var nextRequestId = 1
    private var pendingRequests: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var stdoutBuffer = ""
    private var lastStderrText = ""
    
    var onNotification: (([String: Any]) -> Void)?
    var onStderr: ((String) -> Void)?
    
    private var hasInitialized = false
    private var initTask: Task<Void, Error>?
    
    func start(model: String = "gpt-5.4-mini", sandboxMode: String = "workspace-write", reasoningEffort: String = "high") throws {
        guard process == nil else { return }
        
        guard let exe = CodexRuntimeLocator.executableURL() else {
            throw NSError(domain: "CodexProcess", code: 1, userInfo: [NSLocalizedDescriptionKey: "Codex not installed"])
        }
        
        try CodexHomeManager.shared.setupHome(model: model, sandboxMode: sandboxMode, reasoningEffort: reasoningEffort) // Will be updated in step 10
        
        let p = Process()
        p.executableURL = exe
        p.arguments = ["app-server", "--listen", "stdio://"]
        
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = CodexHomeManager.shared.homeDirectory.path
        env["PATH"] = CodexRuntimeLocator.pathByPrependingBundledRuntimePaths(existingPath: env["PATH"], runtimeExecutableURL: exe)
        p.environment = env
        
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                self?.handleStdout(text)
            }
        }
        
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            self?.queue.async {
                self?.lastStderrText += text
            }
            self?.onStderr?(text)
        }
        
        p.terminationHandler = { [weak self] _ in
            self?.queue.async {
                guard let self = self else { return }
                let errText = self.lastStderrText
                for continuation in self.pendingRequests.values {
                    continuation.resume(throwing: NSError(domain: "CodexProcess", code: -1, userInfo: [NSLocalizedDescriptionKey: "Process terminated. \(errText)"]))
                }
                self.pendingRequests.removeAll()
                self.process = nil
                self.stdoutBuffer = ""
                self.hasInitialized = false
                self.initTask = nil
            }
        }
        
        try p.run()
        
        self.process = p
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe
    }
    
    func stop() {
        queue.sync {
            process?.terminate()
            process = nil
            pendingRequests.values.forEach { $0.resume(throwing: CancellationError()) }
            pendingRequests.removeAll()
            stdoutBuffer = ""
            hasInitialized = false
            initTask = nil
        }
    }
    
    private func handleStdout(_ text: String) {
        stdoutBuffer += text
        let lines = stdoutBuffer.components(separatedBy: "\n")
        stdoutBuffer = lines.last ?? ""
        
        for line in lines.dropLast() {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            
            if let id = json["id"] as? Int, let continuation = pendingRequests.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any] {
                    continuation.resume(throwing: NSError(domain: "CodexRPC", code: 1, userInfo: [NSLocalizedDescriptionKey: error["message"] ?? "Unknown error"]))
                } else if let result = json["result"] as? [String: Any] {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(returning: [:])
                }
            } else {
                onNotification?(json)
            }
        }
    }
    
    func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        if process == nil { throw NSError(domain: "CodexProcess", code: 2, userInfo: [NSLocalizedDescriptionKey: "Process not started before sendRequest"]) }
        
        if method != "initialize" {
            // Await initialization if not already done
            if let task = initTask {
                _ = try await task.value
            } else if !hasInitialized {
                let task = Task {
                    if let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                        _ = try await self.sendRequestInternal(method: "initialize", params: ["clientInfo": ["name": "Pauline", "version": bundleVersion]])
                    } else {
                        _ = try await self.sendRequestInternal(method: "initialize", params: ["clientInfo": ["name": "Pauline", "version": "1.0"]])
                    }
                    self.sendNotification(method: "initialized", params: [:])
                }
                initTask = task
                _ = try await task.value
                hasInitialized = true
            }
        }
        
        return try await sendRequestInternal(method: method, params: params)
    }
    
    private func sendRequestInternal(method: String, params: [String: Any]) async throws -> [String: Any] {
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let id = self.nextRequestId
                self.nextRequestId += 1
                
                let req: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "method": method,
                    "params": params
                ]
                
                do {
                    let data = try JSONSerialization.data(withJSONObject: req)
                    self.pendingRequests[id] = continuation
                    try self.stdinPipe?.fileHandleForWriting.write(contentsOf: data)
                    try self.stdinPipe?.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                } catch {
                    self.pendingRequests.removeValue(forKey: id)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// app-server requires this acknowledgement immediately after initialize.
    /// It is a JSON-RPC notification, so it intentionally has no request id.
    private func sendNotification(method: String, params: [String: Any]) {
        queue.async {
            let notification: [String: Any] = [
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: notification) else { return }
            try? self.stdinPipe?.fileHandleForWriting.write(contentsOf: data)
            try? self.stdinPipe?.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        }
    }
}
