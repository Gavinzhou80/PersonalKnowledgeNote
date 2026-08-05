struct PublicationRecovery {
    let database: LibraryDatabase
    let managedArtifacts: ManagedArtifacts

    func run() throws {
        for recovered in try database.publicationIntents() {
            let finalStatus = try managedArtifacts.finalArtifactStatus(
                recovered.intent
            )
            let stagedStatus = try managedArtifacts.stagedArtifactStatus(
                recovered.intent
            )

            switch finalStatus {
            case .valid(let descriptor):
                _ = try database.finalizeRecoveredIntent(
                    recovered,
                    verifiedDescriptor: descriptor
                )
            case .absent:
                try database.rollbackIntent(
                    taskID: recovered.intent.taskID,
                    preserveStagedOwnership: stagedStatus.isValid
                )
            case .invalid:
                try managedArtifacts.quarantineInvalidFinalArtifact(
                    recovered.intent
                )
                try database.rollbackIntent(
                    taskID: recovered.intent.taskID,
                    preserveStagedOwnership: stagedStatus.isValid
                )
            }
        }
    }
}
