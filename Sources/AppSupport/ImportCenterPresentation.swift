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
}
