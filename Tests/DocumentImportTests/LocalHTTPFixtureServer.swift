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
        let beforeSend: (@Sendable () async throws -> Void)?
        let onSendCompleted: (@Sendable () -> Void)?

        init(
            status: Int = 200,
            headers: [String: String] = [:],
            body: Data = Data(),
            delay: Duration = .zero,
            framing: Framing = .contentLength,
            beforeSend: (@Sendable () async throws -> Void)? = nil,
            onSendCompleted: (@Sendable () -> Void)? = nil
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.delay = delay
            self.framing = framing
            self.beforeSend = beforeSend
            self.onSendCompleted = onSendCompleted
        }
    }

    typealias Handler = @Sendable (String) -> Response

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPFixtureServer")
    private let handler: Handler
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var emptyConnectionWaiters: [UUID: DrainWaiter] = [:]
    private var responseTasks: [UUID: ResponseTaskHandle] = [:]
    private var responseTaskConnections: [UUID: NWConnection] = [:]
    private var emptyResponseTaskWaiters: [UUID: DrainWaiter] = [:]
    private var drainWaiterRegistrations: Set<UUID> = []
    private var preCancelledDrainWaiters: Set<UUID> = []
    private var beforeResponseTaskRegistrationForTesting: (@Sendable () -> Void)?
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
        let stoppedState: (
            [NWConnection],
            [ResponseTaskHandle],
            [DrainWaiter],
            [DrainWaiter]
        ) = lock.withLock {
            beforeResponseTaskRegistrationForTesting = nil
            guard !stopped else { return ([], [], [], []) }
            stopped = true
            let connectionsToCancel = connections
            connections.removeAll()
            let tasksToCancel = Array(responseTasks.values)
            let connectionWaiters = Array(emptyConnectionWaiters.values)
            emptyConnectionWaiters.removeAll()
            let taskWaiters = responseTasks.isEmpty
                ? Array(emptyResponseTaskWaiters.values)
                : []
            if responseTasks.isEmpty { emptyResponseTaskWaiters.removeAll() }
            return (
                connectionsToCancel,
                tasksToCancel,
                connectionWaiters,
                taskWaiters
            )
        }
        stoppedState.0.forEach { $0.cancel() }
        stoppedState.1.forEach { $0.cancel() }
        resumeDrainWaiters(stoppedState.2)
        resumeDrainWaiters(stoppedState.3)
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

    var retainedResponseTaskCountForTesting: Int {
        lock.withLock { responseTasks.count }
    }

    var pendingDrainWaiterCountForTesting: Int {
        lock.withLock {
            emptyConnectionWaiters.count + emptyResponseTaskWaiters.count
                + drainWaiterRegistrations.count + preCancelledDrainWaiters.count
        }
    }

    var hasResponseTaskRegistrationHookForTesting: Bool {
        lock.withLock { beforeResponseTaskRegistrationForTesting != nil }
    }

    func waitUntilNoRetainedConnectionsForTesting(
        timeout: Duration = .seconds(5)
    ) async throws {
        try await waitUntilDrained(.connections, timeout: timeout)
    }

    func waitUntilNoResponseTasksForTesting(
        timeout: Duration = .seconds(5)
    ) async throws {
        try await waitUntilDrained(.responseTasks, timeout: timeout)
    }

    func setBeforeResponseTaskRegistrationForTesting(
        _ hook: @escaping @Sendable () -> Void
    ) {
        lock.withLock { beforeResponseTaskRegistrationForTesting = hook }
    }

    func removeOwnedConnectionsForTesting() {
        let owned = lock.withLock { connections }
        for connection in owned {
            connection.cancel()
            remove(connection)
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
        let registrationHook = lock.withLock {
            let hook = beforeResponseTaskRegistrationForTesting
            beforeResponseTaskRegistrationForTesting = nil
            return hook
        }
        registrationHook?()

        let taskID = UUID()
        let handle = ResponseTaskHandle()
        let shouldStart = lock.withLock {
            guard !stopped,
                  connections.contains(where: { $0 === connection })
            else { return false }
            responseTasks[taskID] = handle
            responseTaskConnections[taskID] = connection
            return true
        }
        guard shouldStart else {
            connection.cancel()
            return
        }
        let task = Task { [weak self, weak connection] in
            defer { self?.finishResponseTask(id: taskID) }
            do {
                try await response.beforeSend?()
                try Task.checkCancellation()
                if response.delay > .zero {
                    try await Task.sleep(for: response.delay)
                }
                try Task.checkCancellation()
            } catch {
                connection?.cancel()
                return
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
        handle.install(task)
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
        let state: (
            [ResponseTaskHandle],
            [DrainWaiter]
        ) = lock.withLock {
            connections.removeAll { $0 === connection }
            let tasks = responseTaskConnections.compactMap { taskID, owner in
                owner === connection ? responseTasks[taskID] : nil
            }
            let waiters: [DrainWaiter]
            if connections.isEmpty {
                waiters = Array(emptyConnectionWaiters.values)
                emptyConnectionWaiters.removeAll()
            } else {
                waiters = []
            }
            return (tasks, waiters)
        }
        state.0.forEach { $0.cancel() }
        resumeDrainWaiters(state.1)
    }

    private func finishResponseTask(id: UUID) {
        let waiters: [DrainWaiter] = lock.withLock {
            responseTasks.removeValue(forKey: id)
            responseTaskConnections.removeValue(forKey: id)
            guard responseTasks.isEmpty else { return [] }
            let result = Array(emptyResponseTaskWaiters.values)
            emptyResponseTaskWaiters.removeAll()
            return result
        }
        resumeDrainWaiters(waiters)
    }

    private func waitUntilDrained(
        _ kind: DrainWaitKind,
        timeout: Duration
    ) async throws {
        try Task.checkCancellation()
        let id = UUID()
        _ = lock.withLock { drainWaiterRegistrations.insert(id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let waiter = DrainWaiter(
                    continuation: continuation,
                    timeoutTask: nil
                )
                let immediate: Result<Void, Error>? = lock.withLock {
                    drainWaiterRegistrations.remove(id)
                    if preCancelledDrainWaiters.remove(id) != nil {
                        return .failure(CancellationError())
                    }
                    let drained = switch kind {
                    case .connections: connections.isEmpty
                    case .responseTasks: responseTasks.isEmpty
                    }
                    if drained { return .success(()) }
                    switch kind {
                    case .connections: emptyConnectionWaiters[id] = waiter
                    case .responseTasks: emptyResponseTaskWaiters[id] = waiter
                    }
                    return nil
                }
                if let immediate {
                    continuation.resume(with: immediate)
                    return
                }
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    self?.resolveDrainWaiter(
                        id: id,
                        with: .failure(DrainWaitError.timeout)
                    )
                }
                let cancelTimeout = lock.withLock {
                    if emptyConnectionWaiters[id] != nil {
                        emptyConnectionWaiters[id]?.timeoutTask = timeoutTask
                        return false
                    }
                    if emptyResponseTaskWaiters[id] != nil {
                        emptyResponseTaskWaiters[id]?.timeoutTask = timeoutTask
                        return false
                    }
                    return true
                }
                if cancelTimeout { timeoutTask.cancel() }
            }
        } onCancel: { [weak self] in
            self?.resolveDrainWaiter(
                id: id,
                with: .failure(CancellationError())
            )
        }
    }

    private func resolveDrainWaiter(
        id: UUID,
        with result: Result<Void, Error>
    ) {
        let waiter: DrainWaiter? = lock.withLock {
            if let waiter = emptyConnectionWaiters.removeValue(forKey: id) {
                return waiter
            }
            if let waiter = emptyResponseTaskWaiters.removeValue(forKey: id) {
                return waiter
            }
            if drainWaiterRegistrations.contains(id),
               case .failure(let error) = result,
               error is CancellationError {
                preCancelledDrainWaiters.insert(id)
            }
            return nil
        }
        guard let waiter else { return }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(with: result)
    }

    private func resumeDrainWaiters(_ waiters: [DrainWaiter]) {
        for waiter in waiters {
            waiter.timeoutTask?.cancel()
            waiter.continuation.resume()
        }
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

private enum DrainWaitKind {
    case connections
    case responseTasks
}

private enum DrainWaitError: Error {
    case timeout
}

private struct DrainWaiter {
    let continuation: CheckedContinuation<Void, Error>
    var timeoutTask: Task<Void, Never>?
}

private final class ResponseTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancellationRequested = false

    func install(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock {
            self.task = task
            return cancellationRequested
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock {
            cancellationRequested = true
            return self.task
        }
        task?.cancel()
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
