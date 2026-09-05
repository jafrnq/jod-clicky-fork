import Foundation

enum CodexRuntimeLocator {
    struct CodexRuntimeVersion: Comparable {
        let major: Int
        let minor: Int
        let patch: Int
        let prerelease: String?
        
        static func < (lhs: CodexRuntimeVersion, rhs: CodexRuntimeVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
            if let lPre = lhs.prerelease, let rPre = rhs.prerelease { return lPre < rPre }
            return lhs.prerelease != nil && rhs.prerelease == nil
        }
    }
    
    static func executableURL(fileManager: FileManager = .default) -> URL? {
        let homeBin = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex")
        if fileManager.isExecutableFile(atPath: homeBin.path) {
            return homeBin
        }
        
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for dir in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(dir)).appendingPathComponent("codex")
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
    
    static func pathByPrependingBundledRuntimePaths(existingPath: String?, runtimeExecutableURL: URL) -> String {
        let runtimeDir = runtimeExecutableURL.deletingLastPathComponent().path
        var components = [String]()
        components.append(runtimeDir)
        if let existing = existingPath, !existing.isEmpty {
            components.append(existing)
        }
        let homeBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        components.append("\(homeBin):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        return components.joined(separator: ":")
    }
}
