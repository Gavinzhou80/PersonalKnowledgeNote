import DocumentImport
import Foundation
import KnowledgeCore
import Observation

/// Adapts the durable import queue to SwiftUI-friendly observable state.
///
/// The store only owns observation and control routing: durable task state
/// lives in `DocumentImport` and its backing library, so recreating the
/// store never cancels or otherwise disturbs in-flight import work.
@MainActor
@Observable
public final class ImportTaskStore {
    public private(set) var tasks: [ImportTaskSnapshot] = []
    public private(set) var controlError: ImportTaskControlError?
    public private(set) var availabilityError: DocumentImportAvailabilityError?
    /// IDs of tasks that reached completion. The display list filters
    /// finished tasks out, so this signal lets views react to
    /// publications (e.g. refreshing the reading list).
    public private(set) var completedTaskIDs: Set<ImportTaskID> = []

    private let importer: DocumentImport
    // Written on the main actor; `nonisolated(unsafe)` allows deinit to
    // cancel observation, which is safe because `Task.cancel()` is.
    nonisolated(unsafe) private var observationTask: Task<Void, Never>?
    nonisolated(unsafe) private var completionObservationTask:
        Task<Void, Never>?

    public init(importer: DocumentImport) {
        self.importer = importer
    }

    deinit {
        observationTask?.cancel()
        completionObservationTask?.cancel()
    }

    /// Boots the importer and observes unfinished tasks.
    ///
    /// Cancels only the previous observation task; durable import work
    /// keeps running regardless of store lifecycle.
    public func start() async {
        stopObserving()
        availabilityError = nil
        do {
            try await importer.start()
        } catch {
            availabilityError = .localLibraryUnavailable
            return
        }
        observeUnfinishedTasks()
    }

    /// Stops observing task updates without touching durable work.
    public func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        completionObservationTask?.cancel()
        completionObservationTask = nil
    }

    public func submit(_ source: OriginalSource) async {
        controlError = nil
        availabilityError = nil
        do {
            _ = try await importer.submit(source)
        } catch let error as ImportSubmissionError {
            if case .localLibraryUnavailable = error {
                availabilityError = .localLibraryUnavailable
            }
            // Validation rejections (invalid URL, unsupported source) are
            // surfaced by the input UI, not synthesized as task failures.
        } catch {
            availabilityError = .localLibraryUnavailable
        }
    }

    public func cancel(id: ImportTaskID) async {
        controlError = nil
        availabilityError = nil
        do {
            try await importer.cancel(taskID: id)
        } catch let error as ImportTaskControlError {
            controlError = error
        } catch {
            availabilityError = .localLibraryUnavailable
        }
    }

    public func retry(id: ImportTaskID) async {
        controlError = nil
        availabilityError = nil
        do {
            try await importer.retry(taskID: id)
        } catch let error as ImportTaskControlError {
            controlError = error
        } catch {
            availabilityError = .localLibraryUnavailable
        }
    }

    private func observeUnfinishedTasks() {
        let stream = importer.observeTasks(.unfinished)
        observationTask = Task { [weak self] in
            for await snapshots in stream {
                guard let self else { return }
                self.tasks = snapshots
            }
        }
        let completionStream = importer.observeTasks(.all)
        completionObservationTask = Task { [weak self] in
            for await snapshots in completionStream {
                guard let self else { return }
                self.completedTaskIDs = Set(
                    snapshots
                        .filter { snapshot in
                            if case .completed = snapshot.state {
                                return true
                            }
                            return false
                        }
                        .map(\.id)
                )
            }
        }
    }
}
