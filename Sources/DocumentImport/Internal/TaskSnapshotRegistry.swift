import Foundation
import KnowledgeCore
import LocalLibrary

struct TaskSnapshotRegistry {
    enum RegistryError: Error {
        case durableCorruption
    }

    struct BatchApplyResult {
        let changedTaskIDs: Set<ImportTaskID>

        var changed: Bool { !changedTaskIDs.isEmpty }
    }

    private struct AttemptKey: Hashable {
        let taskID: ImportTaskID
        let attempt: UInt
    }

    private struct Record {
        var snapshot: ImportTaskSnapshot
        let journalSequence: UInt64
        var queueSequence: UInt64?
        var terminal: ImportTerminalState?
        var observers: [
            UUID: AsyncStream<ImportTaskSnapshot>.Continuation
        ] = [:]
    }

    private struct ListObserver {
        let query: ImportTaskQuery
        let continuation: AsyncStream<[ImportTaskSnapshot]>.Continuation
    }

    private struct PendingTaskObserver {
        let taskID: ImportTaskID
        let continuation: AsyncStream<ImportTaskSnapshot>.Continuation
    }

    private var records: [ImportTaskID: Record] = [:]
    private var listObservers: [UUID: ListObserver] = [:]
    private var pendingTaskObservers: [UUID: PendingTaskObserver] = [:]
    private var waiters: [
        AttemptKey: [CheckedContinuation<ImportTerminalState, Never>]
    ] = [:]
    private(set) var isHydrated = false

    var hasQueuedWork: Bool {
        records.values.contains { record in
            if case .queued = record.snapshot.state { return true }
            return false
        }
    }

    mutating func hydrate(
        _ durableSnapshots: [DurableImportSnapshot]
    ) throws {
        guard !isHydrated else { return }
        let retained = durableSnapshots.filter { $0.state != .abandoned }
        let positions = Self.queuePositions(in: retained)
        var hydrated: [ImportTaskID: Record] = [:]
        hydrated.reserveCapacity(retained.count)
        for durable in retained {
            let snapshot = try Self.project(
                durable,
                queuedPosition: positions[durable.taskID]
            )
            guard hydrated.updateValue(
                Record(
                    snapshot: snapshot,
                    journalSequence: durable.journalSequence,
                    queueSequence: durable.queueSequence,
                    terminal: Self.terminal(for: snapshot.state)
                ),
                forKey: durable.taskID
            ) == nil else {
                throw RegistryError.durableCorruption
            }
        }
        records = hydrated
        isHydrated = true

        let pending = pendingTaskObservers
        pendingTaskObservers.removeAll()
        for (observerID, observer) in pending {
            registerTaskObserver(
                id: observerID,
                taskID: observer.taskID,
                continuation: observer.continuation
            )
        }
        notifyListObservers()
    }

    @discardableResult
    mutating func apply(
        _ durableSnapshots: [DurableImportSnapshot]
    ) throws -> Bool {
        try applyBatch(durableSnapshots).changed
    }

    mutating func applyBatch(
        _ durableSnapshots: [DurableImportSnapshot]
    ) throws -> BatchApplyResult {
        try applyBatch(
            durableSnapshots,
            replacingSameRevision: false
        )
    }

    mutating func reconcileAuthoritative(
        _ durableSnapshots: [DurableImportSnapshot]
    ) throws -> BatchApplyResult {
        try applyBatch(
            durableSnapshots,
            replacingSameRevision: true
        )
    }

    private mutating func applyBatch(
        _ durableSnapshots: [DurableImportSnapshot],
        replacingSameRevision: Bool
    ) throws -> BatchApplyResult {
        guard isHydrated else {
            throw RegistryError.durableCorruption
        }
        var seenTaskIDs: Set<ImportTaskID> = []
        var accepted: [DurableImportSnapshot] = []
        var sameRevision: [DurableImportSnapshot] = []
        for durable in durableSnapshots where durable.state != .abandoned {
            guard seenTaskIDs.insert(durable.taskID).inserted else {
                throw RegistryError.durableCorruption
            }
            guard let existing = records[durable.taskID] else {
                accepted.append(durable)
                continue
            }
            guard existing.journalSequence == durable.journalSequence else {
                throw RegistryError.durableCorruption
            }
            let current = existing.snapshot
            if durable.attempt < current.attempt
                || (durable.attempt == current.attempt
                    && durable.revision < current.revision) {
                continue
            }
            if durable.attempt == current.attempt,
               durable.revision == current.revision {
                if replacingSameRevision {
                    accepted.append(durable)
                } else {
                    sameRevision.append(durable)
                }
                continue
            }
            guard durable.attempt >= current.attempt,
                  durable.revision > current.revision else {
                throw RegistryError.durableCorruption
            }
            accepted.append(durable)
        }

        let positions = Self.queuePositions(
            in: records,
            applyingAccepted: accepted
        )
        for durable in sameRevision {
            guard let existing = records[durable.taskID],
                  existing.queueSequence == durable.queueSequence,
                  try Self.project(
                    durable,
                    queuedPosition: positions[durable.taskID]
                  ) == existing.snapshot else {
                throw RegistryError.durableCorruption
            }
        }

        let acceptedIDs = Set(accepted.map(\.taskID))
        for record in records.values where !acceptedIDs.contains(
            record.snapshot.id
        ) {
            guard case .queued(let currentPosition) = record.snapshot.state
            else { continue }
            guard positions[record.snapshot.id] == currentPosition else {
                throw RegistryError.durableCorruption
            }
        }

        var candidate = records
        var changedSnapshots: [ImportTaskID: ImportTaskSnapshot] = [:]
        for durable in accepted {
            let projected = try Self.project(
                durable,
                queuedPosition: positions[durable.taskID]
            )
            if var existing = candidate[durable.taskID] {
                existing.snapshot = projected
                existing.queueSequence = durable.queueSequence
                existing.terminal = Self.terminal(for: projected.state)
                candidate[durable.taskID] = existing
            } else {
                candidate[durable.taskID] = Record(
                    snapshot: projected,
                    journalSequence: durable.journalSequence,
                    queueSequence: durable.queueSequence,
                    terminal: Self.terminal(for: projected.state)
                )
            }
            changedSnapshots[durable.taskID] = projected
        }

        guard !changedSnapshots.isEmpty else {
            return BatchApplyResult(changedTaskIDs: [])
        }
        records = candidate
        var deliveries: [(
            ImportTaskSnapshot,
            [AsyncStream<ImportTaskSnapshot>.Continuation]
        )] = []
        var terminalDeliveries: [(
            ImportTerminalState,
            [CheckedContinuation<ImportTerminalState, Never>]
        )] = []
        for durable in accepted {
            guard let snapshot = changedSnapshots[durable.taskID],
                  var record = records[durable.taskID] else {
                preconditionFailure("Committed registry record must exist")
            }
            let observers = Array(record.observers.values)
            if let terminal = record.terminal {
                record.observers.removeAll()
                records[durable.taskID] = record
                let key = AttemptKey(
                    taskID: durable.taskID,
                    attempt: durable.attempt
                )
                terminalDeliveries.append((
                    terminal,
                    waiters.removeValue(forKey: key) ?? []
                ))
            }
            deliveries.append((snapshot, observers))
        }
        for (snapshot, observers) in deliveries {
            for observer in observers {
                observer.yield(snapshot)
                if Self.terminal(for: snapshot.state) != nil {
                    observer.finish()
                }
            }
        }
        for (terminal, continuations) in terminalDeliveries {
            for continuation in continuations {
                continuation.resume(returning: terminal)
            }
        }
        notifyListObservers()
        return BatchApplyResult(
            changedTaskIDs: Set(changedSnapshots.keys)
        )
    }

    @discardableResult
    mutating func apply(
        _ snapshot: ImportTaskSnapshot,
        journalSequence: UInt64
    ) throws -> Bool {
        guard var record = records[snapshot.id],
              record.journalSequence == journalSequence else {
            throw RegistryError.durableCorruption
        }
        let current = record.snapshot
        if snapshot.attempt < current.attempt
            || (snapshot.attempt == current.attempt
                && snapshot.revision < current.revision) {
            return false
        }
        if snapshot.attempt == current.attempt,
           snapshot.revision == current.revision {
            guard snapshot == current else {
                throw RegistryError.durableCorruption
            }
            return false
        }
        guard snapshot.attempt >= current.attempt,
              snapshot.revision > current.revision else {
            throw RegistryError.durableCorruption
        }

        record.snapshot = snapshot
        record.terminal = Self.terminal(for: snapshot.state)
        let observers = Array(record.observers.values)
        if let terminal = record.terminal {
            record.observers.removeAll()
            let key = AttemptKey(taskID: snapshot.id, attempt: snapshot.attempt)
            let terminalWaiters = waiters.removeValue(forKey: key) ?? []
            for waiter in terminalWaiters {
                waiter.resume(returning: terminal)
            }
        }
        records[snapshot.id] = record
        for observer in observers {
            observer.yield(snapshot)
            if record.terminal != nil { observer.finish() }
        }
        notifyListObservers()
        return true
    }

    func snapshot(for taskID: ImportTaskID) -> ImportTaskSnapshot? {
        records[taskID]?.snapshot
    }

    func journalSequence(for taskID: ImportTaskID) -> UInt64? {
        records[taskID]?.journalSequence
    }

    mutating func registerListObserver(
        id: UUID,
        query: ImportTaskQuery,
        continuation: AsyncStream<[ImportTaskSnapshot]>.Continuation
    ) {
        listObservers[id] = ListObserver(
            query: query,
            continuation: continuation
        )
        guard isHydrated else { return }
        if case .terminated = continuation.yield(snapshots(matching: query)) {
            listObservers.removeValue(forKey: id)
        }
    }

    mutating func removeListObserver(id: UUID) {
        listObservers.removeValue(forKey: id)
    }

    mutating func registerTaskObserver(
        id: UUID,
        taskID: ImportTaskID,
        continuation: AsyncStream<ImportTaskSnapshot>.Continuation
    ) {
        guard isHydrated else {
            pendingTaskObservers[id] = PendingTaskObserver(
                taskID: taskID,
                continuation: continuation
            )
            return
        }
        guard var record = records[taskID] else {
            continuation.finish()
            return
        }
        if case .terminated = continuation.yield(record.snapshot) { return }
        if record.terminal != nil {
            continuation.finish()
            return
        }
        record.observers[id] = continuation
        records[taskID] = record
    }

    mutating func removeTaskObserver(id: UUID, taskID: ImportTaskID) {
        pendingTaskObservers.removeValue(forKey: id)
        guard var record = records[taskID] else { return }
        record.observers.removeValue(forKey: id)
        records[taskID] = record
    }

    func terminalValue(
        for taskID: ImportTaskID
    ) -> ImportTerminalState? {
        guard let record = records[taskID] else {
            return .failure(Self.privacySafeFailure(
                diagnosticID: taskID.rawValue
            ))
        }
        return record.terminal
    }

    mutating func registerWaiter(
        taskID: ImportTaskID,
        continuation: CheckedContinuation<ImportTerminalState, Never>
    ) {
        guard let record = records[taskID] else {
            continuation.resume(returning: .failure(Self.privacySafeFailure(
                diagnosticID: taskID.rawValue
            )))
            return
        }
        if let terminal = record.terminal {
            continuation.resume(returning: terminal)
            return
        }
        let key = AttemptKey(
            taskID: taskID,
            attempt: record.snapshot.attempt
        )
        waiters[key, default: []].append(continuation)
    }

    func snapshots(
        matching query: ImportTaskQuery
    ) -> [ImportTaskSnapshot] {
        records.values
            .filter { Self.matches($0.snapshot.state, query: query) }
            .sorted(by: Self.recordOrdering)
            .map(\.snapshot)
    }

    private mutating func notifyListObservers() {
        for (id, observer) in Array(listObservers) {
            if case .terminated = observer.continuation.yield(
                snapshots(matching: observer.query)
            ) {
                listObservers.removeValue(forKey: id)
            }
        }
    }

    private static func project(
        _ durable: DurableImportSnapshot,
        queuedPosition: Int?
    ) throws -> ImportTaskSnapshot {
        let source: OriginalSourceSummary
        switch durable.originalSource {
        case .webpage(let url):
            source = .webpage(url)
        case .pdfFile(let url):
            source = .pdfFile(name: url.lastPathComponent)
        }

        let state: ImportTaskState
        switch durable.state {
        case .queued:
            guard let queuedPosition, queuedPosition > 0 else {
                throw RegistryError.durableCorruption
            }
            state = .queued(position: queuedPosition)
        case .running:
            state = .running(progress(for: durable.checkpoint))
        case .publicationPending:
            state = .running(progress(.publishing))
        case .cancelling:
            state = .cancelling
        case .failed:
            state = .failed(privacySafeFailure(
                diagnosticID: durable.taskID.rawValue
            ))
        case .cancelled:
            state = .cancelled
        case .completed:
            guard let outcome = durable.outcome else {
                throw RegistryError.durableCorruption
            }
            switch outcome {
            case .published(let documentID):
                guard let issues = durable.publicationIssues else {
                    throw RegistryError.durableCorruption
                }
                state = .completed(.published(
                    documentID: documentID,
                    issues: issues
                ))
            case .alreadyImported(
                let documentID,
                let location,
                let provenanceAdded
            ):
                state = .completed(.alreadyImported(
                    documentID: documentID,
                    location: location,
                    provenanceAdded: provenanceAdded
                ))
            }
        case .abandoned:
            throw RegistryError.durableCorruption
        case .accepted, .working:
            throw RegistryError.durableCorruption
        }
        return ImportTaskSnapshot(
            id: durable.taskID,
            revision: durable.revision,
            attempt: durable.attempt,
            source: source,
            state: state
        )
    }

    private static func queuePositions(
        in snapshots: [DurableImportSnapshot]
    ) -> [ImportTaskID: Int] {
        Dictionary(uniqueKeysWithValues: snapshots
            .filter { $0.state == .queued }
            .sorted {
                ($0.queueSequence ?? .max) < ($1.queueSequence ?? .max)
            }
            .enumerated()
            .map { ($0.element.taskID, $0.offset + 1) })
    }

    private static func queuePositions(
        in records: [ImportTaskID: Record],
        applyingAccepted updates: [DurableImportSnapshot]
    ) -> [ImportTaskID: Int] {
        var queued = Dictionary(uniqueKeysWithValues: records.values.compactMap {
            record -> (ImportTaskID, UInt64)? in
            guard case .queued = record.snapshot.state,
                  let sequence = record.queueSequence else { return nil }
            return (record.snapshot.id, sequence)
        })
        for update in updates {
            if update.state == .queued, let sequence = update.queueSequence {
                queued[update.taskID] = sequence
            } else {
                queued.removeValue(forKey: update.taskID)
            }
        }
        return Dictionary(uniqueKeysWithValues: queued
            .sorted { $0.value < $1.value }
            .enumerated()
            .map { ($0.element.key, $0.offset + 1) })
    }

    private static func terminal(
        for state: ImportTaskState
    ) -> ImportTerminalState? {
        switch state {
        case .completed(let success): return .success(success)
        case .failed(let failure): return .failure(failure)
        case .cancelled: return .cancelled
        case .queued, .running, .cancelling: return nil
        }
    }

    static func matches(
        _ state: ImportTaskState,
        query: ImportTaskQuery
    ) -> Bool {
        switch query {
        case .all:
            return true
        case .active:
            switch state {
            case .queued, .running, .cancelling: return true
            case .failed, .cancelled, .completed: return false
            }
        case .unfinished:
            switch state {
            case .queued, .running, .cancelling, .failed, .cancelled:
                return true
            case .completed:
                return false
            }
        }
    }

    private static func recordOrdering(_ lhs: Record, _ rhs: Record) -> Bool {
        let lhsRank = rank(lhs.snapshot.state)
        let rhsRank = rank(rhs.snapshot.state)
        if lhsRank != rhsRank { return lhsRank < rhsRank }
        if case .queued = lhs.snapshot.state,
           case .queued = rhs.snapshot.state {
            return queueValue(lhs) < queueValue(rhs)
        }
        return lhs.journalSequence < rhs.journalSequence
    }

    private static func queueValue(_ record: Record) -> UInt64 {
        record.queueSequence ?? .max
    }

    private static func rank(_ state: ImportTaskState) -> Int {
        switch state {
        case .running, .cancelling: return 0
        case .queued: return 1
        case .failed, .cancelled, .completed: return 2
        }
    }

    private static func progress(
        for checkpoint: CheckpointEnvelope?
    ) -> ImportProgress {
        guard let checkpoint,
              let stage = String(data: checkpoint.payload, encoding: .utf8)
        else {
            return progress(.acquiringOriginalSource)
        }
        if stage.contains("publishing") { return progress(.publishing) }
        if stage.contains("constructingSourceDocument") {
            return progress(.constructingSourceDocument)
        }
        return progress(.acquiringOriginalSource)
    }

    private static func progress(_ activity: ImportActivity) -> ImportProgress {
        ImportProgress(
            activity: activity,
            completedUnitCount: 0,
            totalUnitCount: nil
        )
    }

    private static func privacySafeFailure(diagnosticID: UUID) -> ImportFailure {
        ImportFailure(
            code: .localLibraryUnavailable,
            recovery: .requiresUserAction,
            diagnosticID: diagnosticID
        )
    }
}
