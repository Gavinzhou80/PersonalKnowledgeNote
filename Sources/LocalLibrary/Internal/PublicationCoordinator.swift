import KnowledgeCore

struct PublicationCoordinator: Sendable {
    let database: LibraryDatabase
    let managedArtifacts: ManagedArtifacts
    let faultInjector: PublicationFaultInjector

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
            let completion = try database.completeDuplicate(
                taskID: taskID,
                candidate: candidate,
                expectedRevision: expectedRevision,
                faultInjector: faultInjector
            )
            try? managedArtifacts.remove(completion.stagedPlacement)
            return completion.outcome
        case .new(let intent):
            let verifiedPlacement = try managedArtifacts.moveToFinal(intent)
            return try database.finalizePublication(
                candidate: candidate,
                verifiedPlacement: verifiedPlacement
            )
        }
    }
}
