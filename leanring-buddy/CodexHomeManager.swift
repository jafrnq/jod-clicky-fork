import Foundation

class CodexHomeManager {
    static let shared = CodexHomeManager()
    
    let homeDirectory: URL
    
    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        homeDirectory = support.appendingPathComponent("Clicky/CodexHome")
    }
    
    func setupHome(model: String, sandboxMode: String, reasoningEffort: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        
        let globalAuth = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        let localAuth = homeDirectory.appendingPathComponent("auth.json")
        try? fm.removeItem(at: localAuth)
        if fm.fileExists(atPath: globalAuth.path) {
            try? fm.createSymbolicLink(at: localAuth, withDestinationURL: globalAuth)
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
