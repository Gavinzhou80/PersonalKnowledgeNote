import DocumentImport

public struct ImportCenterPresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let systemImage: String

    public init(title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    public static let empty = ImportCenterPresentation(
        title: "Import Center",
        message: "No imports yet",
        systemImage: "tray"
    )

    public static func task(
        _ snapshot: ImportTaskSnapshot
    ) -> ImportCenterPresentation {
        switch snapshot.state {
        case .queued:
            ImportCenterPresentation(
                title: "Import Center",
                message: "Waiting to import",
                systemImage: "clock"
            )

        case let .running(progress):
            switch progress.activity {
            case .acquiringOriginalSource:
                ImportCenterPresentation(
                    title: "Import Center",
                    message: "Acquiring webpage",
                    systemImage: "arrow.down.doc"
                )

            case .constructingSourceDocument:
                ImportCenterPresentation(
                    title: "Import Center",
                    message: "Building source document",
                    systemImage: "doc.text"
                )

            case .publishing:
                ImportCenterPresentation(
                    title: "Import Center",
                    message: "Publishing source document",
                    systemImage: "tray.and.arrow.down"
                )
            }

        case .failed:
            ImportCenterPresentation(
                title: "Import Center",
                message: "Import failed",
                systemImage: "exclamationmark.triangle"
            )

        case let .completed(success):
            switch success {
            case .published:
                ImportCenterPresentation(
                    title: "Import Center",
                    message: "Import completed",
                    systemImage: "checkmark.circle"
                )

            case .alreadyImported:
                ImportCenterPresentation(
                    title: "Import Center",
                    message: "Already imported",
                    systemImage: "checkmark.circle"
                )
            }
        }
    }
}
