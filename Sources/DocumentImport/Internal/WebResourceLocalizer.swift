import CryptoKit
import Foundation
import KnowledgeCore

struct WebLocalizationResult: Sendable {
    let mediaByCandidateKey: [String: SourceMediaReference]
    let issues: [WebLocalizationIssue]
}

struct WebLocalizationIssue: Equatable, Sendable {
    let code: KnowledgeCore.ImportIssue.Code
    let candidateKey: String
}

struct WebResourceLocalizer: Sendable {
    static let maximumImageBytes = 8 * 1024 * 1024
    private static let maximumConcurrentRequests = 4

    func localize(
        _ candidates: [WebImageCandidate],
        into packageURL: URL
    ) async throws -> WebLocalizationResult {
        let assetsURL = try prepareAssetsDirectory(in: packageURL)
        var seenURLs = Set<URL>()
        let uniqueURLs = candidates.reduce(into: [URL]()) { result, candidate in
            guard seenURLs.insert(candidate.resolvedURL).inserted else { return }
            result.append(candidate.resolvedURL)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var downloads: [URL: DownloadResult] = [:]
        var nextIndex = 0
        try await withThrowingTaskGroup(of: (URL, DownloadResult).self) { group in
            func submit(_ url: URL) {
                group.addTask {
                    try Task.checkCancellation()
                    return (url, try await download(url, session: session))
                }
            }
            while nextIndex < min(Self.maximumConcurrentRequests, uniqueURLs.count) {
                submit(uniqueURLs[nextIndex])
                nextIndex += 1
            }
            while let (url, result) = try await group.next() {
                downloads[url] = result
                if nextIndex < uniqueURLs.count {
                    submit(uniqueURLs[nextIndex])
                    nextIndex += 1
                }
            }
        }

        var media: [String: SourceMediaReference] = [:]
        var issues: [WebLocalizationIssue] = []
        for candidate in candidates {
            switch downloads[candidate.resolvedURL] ?? .unavailable {
            case .available(let data, let mimeType, let fileExtension):
                let digest = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }.joined()
                let relativePath = "assets/\(digest).\(fileExtension)"
                try safelyWrite(
                    data,
                    to: assetsURL.appending(path: "\(digest).\(fileExtension)")
                )
                media[candidate.stableKey] = SourceMediaReference(
                    kind: .image,
                    artifactRelativePath: relativePath,
                    mimeType: mimeType,
                    altText: candidate.altText,
                    pixelWidth: nil,
                    pixelHeight: nil
                )
            case .unavailable:
                issues.append(WebLocalizationIssue(
                    code: .optionalWebImageUnavailable,
                    candidateKey: candidate.stableKey
                ))
            }
        }
        return WebLocalizationResult(mediaByCandidateKey: media, issues: issues)
    }

    private func download(
        _ url: URL,
        session: URLSession
    ) async throws -> DownloadResult {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return .unavailable }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let normalized = normalizedImageMIME(http.value(forHTTPHeaderField: "Content-Type")),
                  let fileExtension = extensionForMIME(normalized) else {
                return .unavailable
            }
            if let value = http.value(forHTTPHeaderField: "Content-Length"),
               let length = UInt64(value.trimmingCharacters(in: .whitespaces)),
               length > UInt64(Self.maximumImageBytes) {
                return .unavailable
            }
            var data = Data()
            data.reserveCapacity(min(Self.maximumImageBytes, 64 * 1024))
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumImageBytes else {
                    return .unavailable
                }
                data.append(byte)
            }
            guard !data.isEmpty else { return .unavailable }
            return .available(data, normalized, fileExtension)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return .unavailable
        }
    }

    private func normalizedImageMIME(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return normalized.hasPrefix("image/") ? normalized : nil
    }

    private func extensionForMIME(_ mimeType: String) -> String? {
        switch mimeType {
        case "image/svg+xml": "svg"
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        case "image/avif": "avif"
        default: nil
        }
    }

    private func prepareAssetsDirectory(in packageURL: URL) throws -> URL {
        let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard packageURL.isFileURL, values.isDirectory == true, values.isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let assets = packageURL.appending(path: "assets", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: assets.path) {
            let values = try assets.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        } else {
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: false)
        }
        return assets
    }

    private func safelyWrite(_ data: Data, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  try Data(contentsOf: destination) == data else {
                throw CocoaError(.fileWriteFileExists)
            }
            return
        }
        try data.write(to: destination, options: .atomic)
    }
}

private enum DownloadResult: Sendable {
    case available(Data, String, String)
    case unavailable
}
