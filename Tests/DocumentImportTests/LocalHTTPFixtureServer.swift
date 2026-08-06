import Foundation
import Network

final class LocalHTTPFixtureServer: @unchecked Sendable {
    struct Response: Sendable {
        enum Framing: Sendable {
            case contentLength
            case omitContentLength
            case chunked
        }

        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: Duration
        let framing: Framing
        let onSendCompleted: (@Sendable () -> Void)?

        init(
            status: Int = 200,
            headers: [String: String] = [:],
            body: Data = Data(),
            delay: Duration = .zero,
            framing: Framing = .contentLength,
            onSendCompleted: (@Sendable () -> Void)? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.delay = delay
            self.framing = framing
            self.onSendCompleted = onSendCompleted
        }
    }

    typealias Handler = @Sendable (String) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPFixtureServer")
    private let handler: Handler
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var emptyConnectionWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopped = false
    private(set) var baseURL = URL(string: "http://127.0.0.1:0")!

    private init(listener: NWListener, handler: @escaping Handler) {
        self.listener = listener
        self.handler = handler
    }

    static func start(handler: @escaping Handler) async throws -> LocalHTTPFixtureServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        let listener = try NWListener(using: parameters)
        let server = LocalHTTPFixtureServer(
            listener: listener,
            handler: handler
        )
        server.installConnectionHandler()

        return try await withCheckedThrowingContinuation { continuation in
            let state = LockedStartState()
            listener.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    guard let port = listener.port,
                          state.markResumed()
                    else { return }
                    server.baseURL = URL(
                        string: "http://127.0.0.1:\(port.rawValue)"
                    )!
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: server)
                case .failed(let error):
                    guard state.markResumed() else { return }
                    listener.stateUpdateHandler = nil
                    listener.newConnectionHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    guard state.markResumed() else { return }
                    listener.stateUpdateHandler = nil
                    listener.newConnectionHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "LocalHTTPFixtureServer.start"))
        }
    }

    func url(_ path: String) -> URL {
        let relative = path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return URL(string: relative, relativeTo: baseURL)?.absoluteURL
            ?? baseURL.appending(path: relative)
    }

    func stop() {
        let stoppedState: ([NWConnection], [CheckedContinuation<Void, Never>]) = lock.withLock {
            guard !stopped else { return ([], []) }
            stopped = true
            let result = connections
            connections.removeAll()
            let waiters = emptyConnectionWaiters
            emptyConnectionWaiters.removeAll()
            return (result, waiters)
        }
        stoppedState.0.forEach { $0.cancel() }
        stoppedState.1.forEach { $0.resume() }
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
    }

    deinit {
        stop()
    }

    private func installConnectionHandler() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
    }

    @discardableResult
    private func accept(_ connection: NWConnection) -> Bool {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .failed = state { self.remove(connection) }
            if case .cancelled = state { self.remove(connection) }
        }
        let shouldReceive = lock.withLock {
            guard !stopped else { return false }
            connections.append(connection)
            connection.start(queue: queue)
            return true
        }
        guard shouldReceive else {
            connection.cancel()
            return false
        }
        receiveRequest(on: connection, accumulated: Data())
        return true
    }

    func acceptQueuedConnectionForTesting(_ connection: NWConnection) -> Bool {
        accept(connection)
    }

    var retainedConnectionCountForTesting: Int {
        lock.withLock { connections.count }
    }

    func waitUntilNoRetainedConnectionsForTesting() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if connections.isEmpty { return true }
                emptyConnectionWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if request.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: request, on: connection)
            } else if error == nil, !isComplete, request.count < 64 * 1024 {
                self.receiveRequest(on: connection, accumulated: request)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let requestText = String(decoding: request, as: UTF8.self)
        let path = requestText.split(separator: "\r\n", maxSplits: 1).first?
            .split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let response = handler(path)
        monitorPeerClosure(on: connection)

        Task { [weak self, weak connection] in
            if response.delay > .zero {
                try? await Task.sleep(for: response.delay)
            }
            guard let self, let connection else { return }
            var headers = response.headers
            let body: Data
            switch response.framing {
            case .contentLength:
                headers["Content-Length"] = String(response.body.count)
                body = response.body
            case .omitContentLength:
                headers.removeValue(forKey: "Content-Length")
                body = response.body
            case .chunked:
                headers["Transfer-Encoding"] = "chunked"
                headers.removeValue(forKey: "Content-Length")
                var encoded = Data(
                    String(response.body.count, radix: 16).utf8
                )
                encoded.append(Data("\r\n".utf8))
                encoded.append(response.body)
                encoded.append(Data("\r\n0\r\n\r\n".utf8))
                body = encoded
            }
            headers["Connection"] = "close"
            let reason = Self.reasonPhrase(for: response.status)
            var wire = Data("HTTP/1.1 \(response.status) \(reason)\r\n".utf8)
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                wire.append(Data("\(name): \(value)\r\n".utf8))
            }
            wire.append(Data("\r\n".utf8))
            wire.append(body)
            connection.send(content: wire, completion: .contentProcessed { _ in
                response.onSendCompleted?()
                connection.cancel()
                self.remove(connection)
            })
        }
    }

    private func monitorPeerClosure(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if isComplete || error != nil {
                connection.cancel()
                self.remove(connection)
            } else if data?.isEmpty == false {
                self.monitorPeerClosure(on: connection)
            }
        }
    }

    private func remove(_ connection: NWConnection) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            connections.removeAll { $0 === connection }
            guard connections.isEmpty else { return [] }
            let result = emptyConnectionWaiters
            emptyConnectionWaiters.removeAll()
            return result
        }
        waiters.forEach { $0.resume() }
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 302: "Found"
        case 403: "Forbidden"
        default: "Response"
        }
    }
}

private final class LockedStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func markResumed() -> Bool {
        lock.withLock {
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }
}
