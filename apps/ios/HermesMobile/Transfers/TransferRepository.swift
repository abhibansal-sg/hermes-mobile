import Foundation
import GRDB

actor TransferRepository {
    private let db: DatabaseQueue

    init() throws {
        let url = try Self.databaseURL()
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        db = try DatabaseQueue(path: url.path, configuration: configuration)
        try Self.migrator.migrate(db)
    }

    init(testDB: DatabaseQueue) throws {
        db = testDB
        try Self.migrator.migrate(testDB)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("transfers-v1") { db in
            try db.create(table: TransferRecord.databaseTableName, ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("state", .text).notNull()
                t.column("remoteURL", .text).notNull()
                t.column("localFilePath", .text)
                t.column("destinationFilePath", .text)
                t.column("taskIdentifier", .integer).unique()
                t.column("ownerJobId", .text)
                t.column("ownerWakeDelivered", .boolean).notNull().defaults(to: false)
                t.column("responseBody", .blob)
                t.column("resumeData", .blob)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("nextRetryAt", .double)
                t.column("httpStatus", .integer)
                t.column("errorCode", .text)
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.create(index: "transfers_state", on: TransferRecord.databaseTableName,
                          columns: ["state"], ifNotExists: true)
            try db.create(index: "transfers_owner", on: TransferRecord.databaseTableName,
                          columns: ["ownerJobId", "ownerWakeDelivered"], ifNotExists: true)
        }
        return migrator
    }

    func insert(_ record: TransferRecord) throws {
        try db.write { try record.insert($0) }
    }

    /// Atomically records the system task before the caller is allowed to resume it.
    func bindTask(transferId: String, taskIdentifier: Int) throws {
        try db.write { db in
            guard var record = try TransferRecord.fetchOne(db, key: transferId) else {
                throw TransferError.missingRecord
            }
            record.taskIdentifier = taskIdentifier
            record.state = .running
            record.updatedAt = Date().timeIntervalSince1970
            try record.update(db)
        }
    }

    func record(id: String) throws -> TransferRecord? {
        try db.read { try TransferRecord.fetchOne($0, key: id) }
    }

    func record(taskIdentifier: Int) throws -> TransferRecord? {
        try db.read { db in
            try TransferRecord.filter(Column("taskIdentifier") == taskIdentifier).fetchOne(db)
        }
    }

    func activeRecords() throws -> [TransferRecord] {
        try db.read { db in
            try TransferRecord
                .filter(sql: "state IN (?, ?, ?, ?)", arguments: [
                    TransferState.staged.rawValue, TransferState.running.rawValue,
                    TransferState.retryWaiting.rawValue, TransferState.suspended.rawValue,
                ])
                .fetchAll(db)
        }
    }

    func update(_ record: TransferRecord) throws {
        try db.write { try record.update($0) }
    }

    func remove(id: String) throws {
        _ = try db.write { try TransferRecord.deleteOne($0, key: id) }
    }

    /// Returns an owner id at most once, including across process death.
    func claimOwnerWake(transferId: String) throws -> String? {
        try db.write { db in
            guard var record = try TransferRecord.fetchOne(db, key: transferId),
                  record.state == .completed,
                  !record.ownerWakeDelivered,
                  let owner = record.ownerJobId else { return nil }
            record.ownerWakeDelivered = true
            record.updatedAt = Date().timeIntervalSince1970
            try record.update(db)
            return owner
        }
    }

    private static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("HermesMobile", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appendingPathComponent("transfers.sqlite")
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }
}

enum TransferError: Error, LocalizedError, Sendable {
    case missingRecord
    case missingFile
    case unauthenticated
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .missingRecord: "The transfer record no longer exists."
        case .missingFile: "The transfer file is missing."
        case .unauthenticated: "Authentication is required."
        case .cancelled: "The transfer was cancelled."
        case .failed(let message): message
        }
    }
}
