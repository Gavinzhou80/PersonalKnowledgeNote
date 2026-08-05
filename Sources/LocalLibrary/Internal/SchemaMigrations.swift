import GRDB

enum SchemaMigrations {
    static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_local_library") { db in
            try db.create(table: "import_tasks") { table in
                table.column("task_id", .text).primaryKey()
                table.column("source_kind", .text).notNull()
                table.column("source_value", .text).notNull()
                table.column("attempt", .integer).notNull()
                table.column("revision", .integer).notNull()
                table.column("state", .text).notNull()
                table.column("checkpoint_ordinal", .integer)
                table.column("checkpoint_codec_version", .integer)
                table.column("checkpoint_payload", .blob)
                table.column("staged_artifact_id", .text)
                table.column("outcome_json", .blob)
            }

            try db.create(table: "staged_artifacts") { table in
                table.column("artifact_id", .text).primaryKey()
                table.column("task_id", .text)
                    .notNull()
                    .unique()
                    .references("import_tasks", onDelete: .cascade)
                table.column("descriptor_json", .blob).notNull()
                table.column("relative_path", .text).notNull()
            }

            try db.create(table: "source_documents") { table in
                table.column("document_id", .text).primaryKey()
                table.column("fingerprint", .text).notNull().unique()
                table.column("location", .text).notNull()
                table.column("visibility", .text).notNull()
                table.column("content_json", .blob).notNull()
                table.column("artifact_descriptor_json", .blob).notNull()
                table.column("managed_relative_path", .text).notNull()
            }

            try db.create(table: "source_provenance") { table in
                table.column("document_id", .text)
                    .notNull()
                    .references("source_documents", onDelete: .cascade)
                table.column("source_kind", .text).notNull()
                table.column("source_value", .text).notNull()
                table.primaryKey([
                    "document_id",
                    "source_kind",
                    "source_value",
                ])
            }

            try db.create(table: "publication_intents") { table in
                table.column("task_id", .text)
                    .primaryKey()
                    .references("import_tasks", onDelete: .cascade)
                table.column("document_id", .text).notNull()
                table.column("staged_artifact_id", .text).notNull()
                table.column("final_relative_path", .text).notNull()
            }
        }

        try migrator.migrate(database)
    }
}
