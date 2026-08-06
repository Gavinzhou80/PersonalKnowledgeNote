import Foundation

public enum FixtureCatalog {
    public static let webArticleURL = requiredResource(
        name: "article",
        extension: "html",
        subdirectory: "Web"
    )

    public static let richArticleURL = requiredResource(
        name: "index",
        extension: "html",
        subdirectory: "Web/RichArticle"
    )

    public static let richArticleHeroURL = requiredResource(
        name: "hero",
        extension: "svg",
        subdirectory: "Web/RichArticle"
    )

    public static let minimalPDFURL = requiredResource(
        name: "minimal",
        extension: "pdf",
        subdirectory: "PDF"
    )

    private static func requiredResource(
        name: String,
        extension fileExtension: String,
        subdirectory: String
    ) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            preconditionFailure(
                "Missing fixture: \(subdirectory)/\(name).\(fileExtension)"
            )
        }

        return url
    }
}
