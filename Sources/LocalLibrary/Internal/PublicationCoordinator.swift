import KnowledgeCore

struct PublicationCoordinator: Sendable {
    let database: LibraryDatabase
    let managedArtifacts: ManagedArtifacts

    func finish(
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws -> PublicationOutcome {
        if let outcome = try database.storedOutcome(taskID: taskID) {
            return outcome
        }

        let stagedPlacement = try database.preflightPublication(
            taskID: taskID,
            candidate: candidate,
            expectedRevision: expectedRevision
        )
        _ = try managedArtifacts.verify(stagedPlacement)

        let preparation = try database.preparePublication(
            taskID: taskID,
            candidate: candidate,
            expectedRevision: expectedRevision
        )
        switch preparation {
        case .duplicate(let duplicate):
            _ = try managedArtifacts.verifyStagedArtifact(
                duplicate.candidateIntent
            )
            throw LocalLibraryError.publicationFailed(retryable: true)
        case .new(let intent):
            let verifiedPlacement = try managedArtifacts.moveToFinal(intent)
            return try database.finalizePublication(
                candidate: candidate,
                verifiedPlacement: verifiedPlacement
            )
        }
    }
}
