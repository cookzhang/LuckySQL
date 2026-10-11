import Foundation

// Context gathering stays in AppModel.swift to reuse its private session/cache boundary.
// This file deliberately contains no database or network adapter dependencies.
extension AppModel {
    func openAIAssistance(action: AIAssistantAction = .generate, prompt: String? = nil) {
        section = .query; showAIAssistant = true
        let session = aiAssistant.session(for: activeTabID)
        guard !session.isRunning else { return }
        session.action = action; session.includeSQL = action != .generate
        if let prompt { session.prompt = prompt }
    }
}
