import Foundation

struct URLSessionStaticWebAcquirer: WebAcquiring {
    private static let defaultMaximumResponseBytes = 10 * 1024 * 1024

    private let requestTimeout: TimeInterval
    private let resourceTimeout: TimeInterval
    private let maximumResponseBytes: Int

    init(
        requestTimeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 60,
        maximumResponseBytes: Int = defaultMaximumResponseBytes
    ) {
        precondition(requestTimeout > 0)
        precondition(resourceTimeout > 0)
        precondition(maximumResponseBytes > 0)
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            throw WebAcquisitionError.invalidHTTPResponse
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false

        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: requestTimeout
        )
        request.setValue(
            "text/html, application/xhtml+xml;q=0.9",
            forHTTPHeaderField: "Accept"
        )

        let receiver = BoundedWebResponseReceiver(
            maximumResponseBytes: maximumResponseBytes
        )
        let session = URLSession(
            configuration: configuration,
            delegate: receiver,
            delegateQueue: nil
        )
        return try await receiver.acquire(request, using: session)
    }
}

private final class BoundedWebResponseReceiver: NSObject,
    URLSessionDataDelegate, @unchecked Sendable
{
    private let maximumResponseBytes: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AcquiredWebPage, Error>?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private var terminalError: WebAcquisitionError?
    private weak var session: URLSession?

    init(maximumResponseBytes: Int) {
        self.maximumResponseBytes = maximumResponseBytes
    }

    func acquire(
        _ request: URLRequest,
        using session: URLSession
    ) async throws -> AcquiredWebPage {
        self.session = session
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                session.dataTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              let finalURL = http.url,
              let scheme = finalURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            reject(.invalidHTTPResponse, completionHandler: completionHandler)
            return
        }

        switch http.statusCode {
        case 200..<300:
            break
        case 401, 403:
            reject(.accessDenied, completionHandler: completionHandler)
            return
        default:
            reject(.invalidHTTPResponse, completionHandler: completionHandler)
            return
        }

        guard let mimeType = http.mimeType?.lowercased(),
              mimeType == "text/html" || mimeType == "application/xhtml+xml"
        else {
            reject(.unsupportedContentType, completionHandler: completionHandler)
            return
        }

        if http.expectedContentLength > Int64(maximumResponseBytes) {
            reject(.responseTooLarge, completionHandler: completionHandler)
            return
        }

        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let shouldCancel = lock.withLock {
            guard terminalError == nil else { return true }
            guard bytes.count <= maximumResponseBytes - data.count else {
                terminalError = .responseTooLarge
                return true
            }
            bytes.append(data)
            return false
        }
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let result: Result<AcquiredWebPage, Error> = lock.withLock {
            if let terminalError {
                return .failure(terminalError)
            }
            if let error {
                return .failure(Self.map(error))
            }
            guard let response,
                  let finalURL = response.url,
                  let mimeType = response.mimeType?.lowercased()
            else {
                return .failure(WebAcquisitionError.invalidHTTPResponse)
            }
            return .success(
                AcquiredWebPage(
                    finalURL: finalURL,
                    mimeType: mimeType,
                    responseBytes: bytes
                )
            )
        }
        finish(with: result)
    }

    private func reject(
        _ error: WebAcquisitionError,
        completionHandler: (URLSession.ResponseDisposition) -> Void
    ) {
        lock.withLock { terminalError = error }
        completionHandler(.cancel)
    }

    private func finish(with result: Result<AcquiredWebPage, Error>) {
        let continuation = lock.withLock {
            let result = self.continuation
            self.continuation = nil
            return result
        }
        guard let continuation else { return }
        continuation.resume(with: result)
        session?.finishTasksAndInvalidate()
    }

    private static func map(_ error: Error) -> WebAcquisitionError {
        guard let urlError = error as? URLError else {
            return .networkUnavailable
        }
        switch urlError.code {
        case .timedOut:
            return .requestTimedOut
        case .badURL,
             .unsupportedURL,
             .redirectToNonExistentLocation,
             .badServerResponse,
             .zeroByteResource,
             .cannotDecodeRawData,
             .cannotDecodeContentData,
             .cannotParseResponse:
            return .invalidHTTPResponse
        case .userAuthenticationRequired,
             .userCancelledAuthentication:
            return .accessDenied
        case .dataLengthExceedsMaximum:
            return .responseTooLarge
        case .cancelled:
            return .networkUnavailable
        default:
            return .networkUnavailable
        }
    }
}
