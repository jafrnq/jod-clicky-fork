import Foundation

@MainActor
protocol AgentBackend: AnyObject {
    var model: String { get set }
    var maxOutputTokens: Int { get set }
    var agentModeEnabled: Bool { get set }
    
    func warmUp(systemPrompt: String)
    
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        assistantPrefill: String?,
        onTextChunk: @MainActor @Sendable @escaping (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval)
    
    func stop()
}
