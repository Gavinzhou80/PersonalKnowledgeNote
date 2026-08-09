import KnowledgeCore

struct PublicationCoordinator: Sendable {
    let database: LibraryDatabase
    let managedArtifacts: ManagedArtifacts
    let faultInjector: PublicationFaultInjector

    func finish(
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws -> PublicationCompletion {
        if let outcome = try database.storedOutcome(taskID: taskID) {
            return PublicationCompletion(
                outcome: outcome,
                checkpointCleanup: nil
            )
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
            try faultInjector.hit(.beforeCommittedStagingCleanup)
            try? managedArtifacts.remove(completion.stagedPlacement)
            return PublicationCompletion(
                outcome: completion.outcome,
                checkpointCleanup: completion.checkpointCleanup
            )
        case .new(let intent):
            try faultInjector.hit(.afterIntentCommit)
            try managedArtifacts.moveToFinalAtomically(intent)
            try faultInjector.hit(.afterArtifactMove)
            let verifiedPlacement = try managedArtifacts
                .verifyFinalPublication(intent)
            try faultInjector.hit(.beforeVisibilityCommit)
            let completion = try database.finalizePublication(
                candidate: candidate,
                verifiedPlacement: verifiedPlacement
            )
            try faultInjector.hit(.afterVisibilityCommit)
            return completion
        }
    }
}
