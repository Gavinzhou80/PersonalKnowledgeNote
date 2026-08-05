import AppSupport
import SwiftUI

struct ImportCenterView: View {
    let presentation: ImportCenterPresentation

    var body: some View {
        ContentUnavailableView(
            presentation.title,
            systemImage: presentation.systemImage,
            description: Text(presentation.message)
        )
        .frame(minWidth: 560, minHeight: 360)
    }
}
