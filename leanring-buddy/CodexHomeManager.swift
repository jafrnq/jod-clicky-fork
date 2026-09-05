import Foundation

class CodexHomeManager {
    static let shared = CodexHomeManager()
    
    let homeDirectory: URL
    
    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        // V6 keeps its account session separate so sign-in and sign-out never
        // alter the existing Pauline V5 Codex installation.
        homeDirectory = support.appendingPathComponent("Pauline V6/CodexHome")
    }
    
    func setupHome(model: String, sandboxMode: String, reasoningEffort: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        
        let localAuth = homeDirectory.appendingPathComponent("auth.json")
        // Remove only a legacy V6-local symlink. The app-server owns the
        // replacement credential after the user completes ChatGPT sign-in.
        if let _ = try? fm.destinationOfSymbolicLink(atPath: localAuth.path) {
            try? fm.removeItem(at: localAuth)
        }
        
        // Touch empty memory
        let memory = homeDirectory.appendingPathComponent("memory.md")
        if !fm.fileExists(atPath: memory.path) {
            try "".write(to: memory, atomically: true, encoding: .utf8)
        }
        
        // Write config
        let config = ClickyCodexConfigTemplate.generateToml(model: model, sandboxMode: sandboxMode, reasoningEffort: reasoningEffort)
        try config.write(to: homeDirectory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }
}
