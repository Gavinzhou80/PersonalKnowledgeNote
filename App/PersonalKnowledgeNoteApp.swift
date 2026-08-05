import AppSupport
import SwiftUI

@main
struct PersonalKnowledgeNoteApp: App {
    var body: some Scene {
        WindowGroup("Import Center") {
            ImportCenterView(presentation: .empty)
        }
        .defaultSize(width: 720, height: 520)
    }
}
