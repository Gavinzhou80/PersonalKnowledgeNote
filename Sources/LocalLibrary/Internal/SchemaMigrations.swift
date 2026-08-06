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

        migrator.registerMigration("v2_durable_import_queue") { db in
            try db.alter(table: "import_tasks") { table in
                table.add(column: "journal_sequence", .integer)
                table.add(column: "queue_sequence", .integer)
                table.add(column: "failure_codec_version", .integer)
                table.add(column: "failure_payload", .blob)
                table.add(column: "cancellation_requested", .boolean)
                    .notNull()
                    .defaults(to: false)
            }

            try db.execute(
                sql: """
                    UPDATE import_tasks
                    SET state = 'queued'
                    WHERE state IN ('accepted', 'working')
                    """
            )
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT task_id
                    FROM import_tasks
                    ORDER BY rowid
                    """
            )
            for (offset, row) in rows.enumerated() {
                let taskID = try row.decode(
                    String.self,
                    forColumn: "task_id"
                )
                let sequence = Int64(offset) + 1
                try db.execute(
                    sql: """
                        UPDATE import_tasks
                        SET journal_sequence = ?,
                            queue_sequence = CASE
                                WHEN state = 'queued' THEN ?
                                ELSE NULL
                            END
                        WHERE task_id = ?
                        """,
                    arguments: [
                        sequence,
                        sequence,
                        taskID,
                    ]
                )
            }

            try db.create(
                index: "import_tasks_journal_sequence",
                on: "import_tasks",
                columns: ["journal_sequence"],
                unique: true
            )
            try db.execute(
                sql: """
                    CREATE UNIQUE INDEX import_tasks_active_queue
                    ON import_tasks(queue_sequence)
                    WHERE queue_sequence IS NOT NULL
                    """
            )
            try db.execute(
                sql: """
                    CREATE TABLE import_queue_clock (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        last_sequence INTEGER NOT NULL CHECK (last_sequence >= 0)
                    )
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO import_queue_clock(singleton, last_sequence)
                    VALUES (1, ?)
                    """,
                arguments: [rows.count]
            )
        }

        try migrator.migrate(database)
    }
}
