import AppKit
import Darwin

@MainActor enum AgentCommandRunner {
    static let workspaceURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".clicky/workspace", isDirectory: true)
    static let proceduresURL = workspaceURL.appendingPathComponent("procedures", isDirectory: true)
    
    static func ensureWorkspaceExists() {
        let fm = FileManager.default
        try? fm.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: proceduresURL, withIntermediateDirectories: true)
        let notesURL = workspaceURL.appendingPathComponent("NOTES.md")
        if !fm.fileExists(atPath: notesURL.path) {
            try? "".write(to: notesURL, atomically: true, encoding: .utf8)
        }
    }
    
    static func saveProcedure(trigger: String, recipe: String) {
        let safeName = trigger.replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-").lowercased()
        let fileURL = proceduresURL.appendingPathComponent("\(safeName).md")
        let content = "TRIGGER: \(trigger)\n\n\(recipe)"
        try? content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
    
    static func askUserToApprove(command: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Pauline wants to confirm"
        alert.informativeText = command
        alert.addButton(withTitle: "Cancel")   // FIRST = default = safe
        alert.addButton(withTitle: "Run")
        return alert.runModal() == .alertSecondButtonReturn
    }
    
    /// Runs an approved shell command off the main actor. Bounded output plus a
    /// hard kill so a hung command can never wedge the voice pipeline.
    static func run(command: String) async -> String {
        let workspace = workspaceURL
        return await Task.detached(priority: .userInitiated) {
            runOffMainThread(command: command, workspace: workspace)
        }.value
    }

    nonisolated private static func runOffMainThread(command: String, workspace: URL) -> String {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", command]
        task.currentDirectoryURL = workspace
        // Never inherit our stdin — a command that prompts would block forever.
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            return "Error: \(error.localizedDescription)"
        }
        let processIdentifier = task.processIdentifier
        let watchdog = DispatchWorkItem { kill(processIdentifier, SIGKILL) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: watchdog)
        var collectedOutput = Data()
        var didExceedOutputCap = false
        let readHandle = pipe.fileHandleForReading
        while true {
            let chunk = readHandle.availableData
            if chunk.isEmpty { break }
            collectedOutput.append(chunk)
            if collectedOutput.count >= 64_000 { didExceedOutputCap = true; break }
        }
        if didExceedOutputCap { kill(processIdentifier, SIGKILL) }
        task.waitUntilExit()
        watchdog.cancel()
        let output = String(data: collectedOutput, encoding: .utf8) ?? ""
        return String(output.prefix(4000))
    }
}
