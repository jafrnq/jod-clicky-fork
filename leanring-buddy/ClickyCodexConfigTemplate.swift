import Foundation

struct ClickyCodexConfigTemplate {
    static func generateToml(model: String, sandboxMode: String, reasoningEffort: String) -> String {
        let cuaDriverPath = resolvedCuaDriverPath()
        return """
        model = "\(model)"
        model_provider = "openai"
        model_reasoning_effort = "\(reasoningEffort)"
        preferred_auth_method = "chatgpt"
        approval_policy = "never"
        sandbox_mode = "\(sandboxMode)"
        
        [mcp_servers.cuaDriver]
        command = "\(cuaDriverPath)"
        args = ["mcp"]
        
        [mcp_servers.cuaDriver.env]
        TELEMETRY_DISABLED = "true"
        
        [skills]
        learned_skills_enabled = true
        """
    }
    
    static func resolvedCuaDriverPath() -> String {
        let fm = FileManager.default
        let paths = [
            "/Applications/CuaDriver.app/Contents/MacOS/cua-driver",
            "/usr/local/bin/cua-driver",
            "/opt/homebrew/bin/cua-driver",
            fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/cua-driver").path
        ]
        for path in paths {
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return "cua-driver"
    }
}
