import Foundation

struct AgentReasoningOption: Equatable {
    let value: String
    let displayName: String
}

struct AgentModelOption: Equatable, Identifiable {
    let id: String
    let displayName: String
    let isDefault: Bool
    let supportedReasoningEfforts: [AgentReasoningOption]
    let defaultReasoningEffort: String
}

enum AgentModelCatalogState {
    case notLoaded
    case loading
    case loaded([AgentModelOption])
    case unavailable(reason: String)
}

struct AgentModelCatalog {
    static let claudeModels: [AgentModelOption] = [
        AgentModelOption(
            id: "claude-sonnet-4-6",
            displayName: "Claude 3.5 Sonnet",
            isDefault: true,
            supportedReasoningEfforts: [
                AgentReasoningOption(value: "low", displayName: "Low"),
                AgentReasoningOption(value: "medium", displayName: "Medium"),
                AgentReasoningOption(value: "high", displayName: "High"),
                AgentReasoningOption(value: "xhigh", displayName: "Xhigh"),
                AgentReasoningOption(value: "max", displayName: "Max")
            ],
            defaultReasoningEffort: "high"
        ),
        AgentModelOption(
            id: "claude-haiku-4-5",
            displayName: "Claude 3.5 Haiku",
            isDefault: false,
            supportedReasoningEfforts: [
                AgentReasoningOption(value: "low", displayName: "Low"),
                AgentReasoningOption(value: "medium", displayName: "Medium"),
                AgentReasoningOption(value: "high", displayName: "High"),
                AgentReasoningOption(value: "xhigh", displayName: "Xhigh"),
                AgentReasoningOption(value: "max", displayName: "Max")
            ],
            defaultReasoningEffort: "high"
        ),
        AgentModelOption(
            id: "claude-opus-4-6",
            displayName: "Claude 3 Opus",
            isDefault: false,
            supportedReasoningEfforts: [
                AgentReasoningOption(value: "low", displayName: "Low"),
                AgentReasoningOption(value: "medium", displayName: "Medium"),
                AgentReasoningOption(value: "high", displayName: "High"),
                AgentReasoningOption(value: "xhigh", displayName: "Xhigh"),
                AgentReasoningOption(value: "max", displayName: "Max")
            ],
            defaultReasoningEffort: "high"
        )
    ]
    
    static func resolveEffort(saved: String?, for model: AgentModelOption) -> String {
        let supportsHigh = model.supportedReasoningEfforts.contains(where: { $0.value == "high" })
        if let savedValue = saved, model.supportedReasoningEfforts.contains(where: { $0.value == savedValue }) {
            return savedValue
        }
        if supportsHigh {
            return "high"
        }
        return model.defaultReasoningEffort
    }
}
