import Foundation
import KnowledgeCore
import LocalLibrary

enum WebImportStage: UInt64 {
    case acquiring = 1
    case acquired = 2
    case constructing = 3
    case prepared = 4
    case publishing = 5
}

enum T05CrashPoint: CaseIterable, Sendable {
    case afterAcceptance
    case afterAcquiredCheckpoint
    case afterPreparedCheckpoint
    case afterPublicationIntent
    case afterArtifactMove
    case afterVisibilityCommit
    case duringCancellationCleanup
}

enum ImportTaskRunnerInterruption: Error, Sendable {
    case injectedProcessTermination
}

typealias ImportRunnerBoundaryHook = @Sendable (
    T05CrashPoint
) async throws -> Void

struct PersistedImportFailure: Codable, Sendable {
    let code: ImportFailure.Code
    let recovery: ImportFailure.Recovery
    let diagnosticID: UUID
}

private enum WebImportResumePoint {
    case acquireFresh
    case acquired(ManagedCheckpointArtifact)
    case prepared(ManagedCheckpointArtifact)
}

extension DocumentImport {
    func runResumableWebImport(
        workspace: ImportWorkspace,
        source: OriginalSource,
        sourceURL: URL
    ) async {
        do {
            try await executeResumableWebImport(
                workspace: workspace,
                source: source,
                sourceURL: sourceURL
            )
        } catch is ImportTaskRunnerInterruption {
            return
        } catch {
            await failTask(workspace: workspace, error: error)
        }
    }

    private func executeResumableWebImport(
        workspace: ImportWorkspace,
        source: OriginalSource,
        sourceURL: URL
    ) async throws {
        let claimed = try await workspaceSnapshotLoader(workspace)
        try await boundaryHook(.afterAcceptance)

        switch try Self.resumePoint(from: claimed) {
        case .acquireFresh:
            let acquiring = try await workspace.checkpoint(
                CheckpointUpdate(
                    expectedRevision: claimed.revision,
                    ordinal: WebImportStage.acquiring.rawValue,
                    envelope: Self.webCheckpointEnvelope(
                        "acquiringOriginalSource"
                    )
                )
            )
            updateSnapshot(
                taskID: workspace.taskID,
                revision: acquiring.revision,
                state: .running(Self.progress(.acquiringOriginalSource))
            )
            let page = try await webAcquirer.acquire(sourceURL)
            let acquiredRevision = try await persistAcquiredCheckpoint(
                page: page,
                workspace: workspace,
                expectedRevision: acquiring.revision
            )
            try await constructAndPublish(
                page: page,
                workspace: workspace,
                source: source,
                sourceURL: sourceURL,
                expectedRevision: acquiredRevision
            )
        case .acquired(let artifact):
            updateSnapshot(
                taskID: workspace.taskID,
                revision: claimed.revision,
                state: .running(
                    Self.progress(.constructingSourceDocument)
                )
            )
            let page = try await loadAcquiredPage(
                workspace: workspace,
                artifact: artifact
            )
            try await constructAndPublish(
                page: page,
                workspace: workspace,
                source: source,
                sourceURL: sourceURL,
                expectedRevision: claimed.revision
            )
        case .prepared(let artifact):
            updateSnapshot(
                taskID: workspace.taskID,
                revision: claimed.revision,
                state: .running(Self.progress(.publishing))
            )
            let prepared = try await loadPreparedPublication(
                workspace: workspace,
                artifact: artifact
            )
            try await publishPrepared(
                prepared,
                workspace: workspace,
                sourceURL: sourceURL,
                expectedRevision: claimed.revision
            )
        }
    }

    private func persistAcquiredCheckpoint(
        page: AcquiredWebPage,
        workspace: ImportWorkspace,
        expectedRevision: UInt64
    ) async throws -> UInt64 {
        let encoded = try WebImportCheckpointCodec.writeAcquired(page)
        let replacement: CheckpointArtifactReplacement
        do {
            replacement = try await workspace.replaceCheckpointArtifact(
                packageURL: encoded.url,
                update: CheckpointUpdate(
                    expectedRevision: expectedRevision,
                    ordinal: WebImportStage.acquired.rawValue,
                    envelope: Self.webCheckpointEnvelope(
                        "constructingSourceDocument"
                    )
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: encoded.url)
            throw error
        }
        try? FileManager.default.removeItem(at: encoded.url)
        updateSnapshot(
            taskID: workspace.taskID,
            revision: replacement.snapshot.revision,
            state: .running(Self.progress(.constructingSourceDocument))
        )
        try await boundaryHook(.afterAcquiredCheckpoint)
        return replacement.snapshot.revision
    }

    private func constructAndPublish(
        page: AcquiredWebPage,
        workspace: ImportWorkspace,
        source: OriginalSource,
        sourceURL: URL,
        expectedRevision: UInt64
    ) async throws {
        let documentID = documentIDGenerator()
        let product = try await webDocumentBuilder(page, documentID)
        let artifact = try await workspace.stageArtifact(
            .package(product.packageURL, descriptor: product.descriptor),
            expectedRevision: expectedRevision
        )
        try? FileManager.default.removeItem(at: product.packageURL)
        let staged = try await workspace.snapshot()

        let prepared = PreparedWebPublication(
            documentID: documentID,
            fingerprint: product.fingerprint,
            document: product.document.content,
            originalSource: source,
            stagedArtifactID: artifact.rawValue,
            stagedDescriptor: artifact.descriptor,
            issues: product.issues
        )
        let encoded = try WebImportCheckpointCodec.writePrepared(prepared)
        let replacement: CheckpointArtifactReplacement
        do {
            replacement = try await workspace.replaceCheckpointArtifact(
                packageURL: encoded.url,
                update: CheckpointUpdate(
                    expectedRevision: staged.revision,
                    ordinal: WebImportStage.prepared.rawValue,
                    envelope: Self.webCheckpointEnvelope("publishing")
                )
            )
        } catch {
            try? FileManager.default.removeItem(at: encoded.url)
            throw error
        }
        try? FileManager.default.removeItem(at: encoded.url)
        updateSnapshot(
            taskID: workspace.taskID,
            revision: replacement.snapshot.revision,
            state: .running(Self.progress(.publishing))
        )
        try await boundaryHook(.afterPreparedCheckpoint)

        try await publishCandidate(
            PublicationCandidate(
                fingerprint: product.fingerprint,
                artifact: artifact,
                document: product.document.content,
                originalSource: source
            ),
            publishedIssues: product.issues,
            workspace: workspace,
            sourceURL: sourceURL,
            expectedRevision: replacement.snapshot.revision
        )
    }

    private func loadAcquiredPage(
        workspace: ImportWorkspace,
        artifact: ManagedCheckpointArtifact
    ) async throws -> AcquiredWebPage {
        do {
            let package = try await workspace.loadCheckpointArtifact(artifact)
            return try WebImportCheckpointCodec.readAcquired(package)
        } catch {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private func loadPreparedPublication(
        workspace: ImportWorkspace,
        artifact: ManagedCheckpointArtifact
    ) async throws -> PreparedWebPublication {
        do {
            let package = try await workspace.loadCheckpointArtifact(artifact)
            return try WebImportCheckpointCodec.readPrepared(package)
        } catch {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private func publishPrepared(
        _ prepared: PreparedWebPublication,
        workspace: ImportWorkspace,
        sourceURL: URL,
        expectedRevision: UInt64
    ) async throws {
        let stagedArtifact = StagedArtifact(
            rawValue: prepared.stagedArtifactID,
            descriptor: prepared.stagedDescriptor
        )
        _ = try await workspace.verifyManagedArtifact(stagedArtifact)
        try await publishCandidate(
            PublicationCandidate(
                fingerprint: prepared.fingerprint,
                artifact: stagedArtifact,
                document: prepared.document,
                originalSource: prepared.originalSource
            ),
            publishedIssues: prepared.issues,
            workspace: workspace,
            sourceURL: sourceURL,
            expectedRevision: expectedRevision
        )
    }

    private func publishCandidate(
        _ candidate: PublicationCandidate,
        publishedIssues: [KnowledgeCore.ImportIssue],
        workspace: ImportWorkspace,
        sourceURL: URL,
        expectedRevision: UInt64
    ) async throws {
        let outcome = try await workspace.finish(
            candidate,
            expectedRevision: expectedRevision
        )
        let completed = try? await workspaceSnapshotLoader(workspace)
        let terminalRevision = completed?.revision
            ?? Self.completionRevision(
                after: expectedRevision,
                outcome: outcome
            )
        finishTask(
            taskID: workspace.taskID,
            snapshot: ImportTaskSnapshot(
                id: workspace.taskID,
                revision: terminalRevision,
                attempt: completed?.attempt ?? 1,
                source: .webpage(sourceURL),
                state: .completed(Self.success(
                    for: outcome,
                    publishedIssues: publishedIssues
                ))
            )
        )
    }

    private static func resumePoint(
        from snapshot: DurableImportSnapshot
    ) throws -> WebImportResumePoint {
        guard let checkpoint = snapshot.checkpoint else {
            return .acquireFresh
        }
        guard checkpoint.codecVersion == 1,
              let ordinal = snapshot.checkpointOrdinal,
              let stage = WebImportStage(rawValue: ordinal)
        else {
            throw WebImportCheckpointError.invalidPackage
        }
        switch stage {
        case .acquiring:
            return .acquireFresh
        case .acquired, .constructing:
            guard let artifact = snapshot.checkpointArtifact else {
                throw WebImportCheckpointError.invalidPackage
            }
            return .acquired(artifact)
        case .prepared, .publishing:
            guard let artifact = snapshot.checkpointArtifact else {
                throw WebImportCheckpointError.invalidPackage
            }
            return .prepared(artifact)
        }
    }

    static func webCheckpointEnvelope(
        _ stage: String
    ) -> CheckpointEnvelope {
        CheckpointEnvelope(codecVersion: 1, payload: Data(stage.utf8))
    }

    private static func completionRevision(
        after expectedRevision: UInt64,
        outcome: PublicationOutcome
    ) -> UInt64 {
        let increment: UInt64
        switch outcome {
        case .published:
            increment = 2
        case .alreadyImported:
            increment = 1
        }
        let (revision, overflow) = expectedRevision
            .addingReportingOverflow(increment)
        precondition(
            !overflow,
            "A successful Local Library finish must have completed its durable revision increments"
        )
        return revision
    }
}
