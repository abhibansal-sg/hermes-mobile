import Foundation

/// Relaunch-safe owner of Hermes' one fixed background URLSession.
final class TransferManager: NSObject, @unchecked Sendable {
    static let backgroundSessionIdentifier = "ai.hermes.app.transfers.background.v1"
    static let shared = TransferManager()

    typealias HeaderProvider = @Sendable (TransferRecord) async -> [String: String]
    typealias OwnerWaker = @Sendable (String, String) async -> Void

    private let repository: TransferRepository
    private let fileManager: FileManager
    private let sessionIdentifier: String
    private let lock = NSLock()
    private var responseBodies: [Int: Data] = [:]
    private var downloadLocations: [Int: URL] = [:]
    private var waiters: [String: CheckedContinuation<TransferRecord, Error>] = [:]
    private var backgroundCompletions: [() -> Void] = []
    private var pendingCompletionProcessing = 0
    private var backgroundEventsFinished = false
    private var headerProvider: HeaderProvider = { _ in [:] }
    private var ownerWaker: OwnerWaker?
    private(set) lazy var session: URLSession = makeSession()

    override convenience init() {
        do { try self.init(repository: TransferRepository()) }
        catch { fatalError("Unable to open durable transfer store: \(error.localizedDescription)") }
    }

    init(repository: TransferRepository, fileManager: FileManager = .default,
         sessionIdentifier: String = TransferManager.backgroundSessionIdentifier) {
        self.repository = repository
        self.fileManager = fileManager
        self.sessionIdentifier = sessionIdentifier
        super.init()
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.background(
            withIdentifier: sessionIdentifier
        )
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self,
                          delegateQueue: OperationQueue())
    }

    /// Called during app construction, before connection bootstrap.
    func initializeEarly() {
        _ = session
        Task { await reconcile() }
    }

    func configure(headerProvider: @escaping HeaderProvider, ownerWaker: OwnerWaker? = nil) {
        lock.withLock {
            self.headerProvider = headerProvider
            self.ownerWaker = ownerWaker
        }
        Task { await reconcile() }
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        lock.withLock { backgroundCompletions.append(handler) }
    }

    func uploadMultipart(
        data: Data,
        filename: String,
        mimeType: String,
        to url: URL,
        headers: [String: String],
        ownerJobId: String? = nil
    ) async throws -> TransferRecord {
        let boundary = "Boundary-\(UUID().uuidString)"
        let file = try stageMultipart(data: data, filename: filename,
                                      mimeType: mimeType, boundary: boundary)
        var safeHeaders = headers
        safeHeaders["Content-Type"] = "multipart/form-data; boundary=\(boundary)"
        return try await enqueueUpload(file: file, to: url, headers: safeHeaders,
                                       ownerJobId: ownerJobId, waitForCompletion: true)
    }

    func enqueueUpload(
        file: URL,
        to url: URL,
        headers: [String: String] = [:],
        ownerJobId: String? = nil,
        waitForCompletion: Bool = false
    ) async throws -> TransferRecord {
        guard fileManager.fileExists(atPath: file.path) else { throw TransferError.missingFile }
        let protected = try protectAndAdopt(file)
        let record = makeRecord(kind: .upload, remoteURL: url,
                                localFile: protected, destination: nil, ownerJobId: ownerJobId)
        try await repository.insert(record)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.uploadTask(with: request, fromFile: protected)
        // The ordering is contractual: durable row + task id commit, then resume.
        try await repository.bindTask(transferId: record.id, taskIdentifier: task.taskIdentifier)
        task.resume()
        guard waitForCompletion else { return try await repository.record(id: record.id)! }
        return try await waitForTransfer(id: record.id)
    }

    func enqueueDownload(
        from url: URL,
        to destination: URL,
        kind: TransferKind = .download,
        headers: [String: String] = [:],
        ownerJobId: String? = nil
    ) async throws -> TransferRecord {
        precondition(kind == .download || kind == .export)
        let record = makeRecord(kind: kind, remoteURL: url, localFile: nil,
                                destination: destination, ownerJobId: ownerJobId)
        try await repository.insert(record)
        var request = URLRequest(url: url)
        var resolvedHeaders = await currentHeaders(for: record)
        resolvedHeaders.merge(headers) { _, explicit in explicit }
        for (key, value) in resolvedHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let task = session.downloadTask(with: request)
        try await repository.bindTask(transferId: record.id, taskIdentifier: task.taskIdentifier)
        task.resume()
        return try await repository.record(id: record.id)!
    }

    func cancel(id: String) async {
        guard let record = try? await repository.record(id: id),
              let identifier = record.taskIdentifier else { return }
        let tasks = await allTasks()
        tasks.first { $0.taskIdentifier == identifier }?.cancel()
    }

    func reconcile() async {
        let tasks = await allTasks()
        let taskIds = Set(tasks.map(\.taskIdentifier))
        let records = (try? await repository.activeRecords()) ?? []
        var known: [Int: TransferRecord] = [:]
        for record in records { if let id = record.taskIdentifier { known[id] = record } }

        for var record in records where record.taskIdentifier == nil || !taskIds.contains(record.taskIdentifier!) {
            if record.state == .staged || record.state == .running || record.state == .suspended {
                record.state = .failed
                record.errorCode = record.localFilePath.map { fileManager.fileExists(atPath: $0) }
                    == false ? "missing_file" : "orphan_row"
                record.updatedAt = Date().timeIntervalSince1970
                try? await repository.update(record)
                finishWaiter(record)
            }
        }
        for task in tasks where known[task.taskIdentifier] == nil {
            task.cancel() // orphan system task: no durable owner, never let it write anonymously.
        }
    }

    private func waitForTransfer(id: String) async throws -> TransferRecord {
        if let record = try await repository.record(id: id),
           [.completed, .failed, .cancelled].contains(record.state) {
            return try terminalResult(record)
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { waiters[id] = continuation }
        }
    }

    private func processCompletion(task: URLSessionTask, error: Error?) async {
        guard var record = try? await repository.record(taskIdentifier: task.taskIdentifier) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        record.httpStatus = status
        record.responseBody = lock.withLock { responseBodies.removeValue(forKey: task.taskIdentifier) }
        record.updatedAt = Date().timeIntervalSince1970

        if let urlError = error as? URLError, urlError.code == .cancelled {
            record.state = .cancelled
            record.errorCode = "cancelled"
        } else if let error {
            let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            record.resumeData = resumeData
            record.state = resumeData == nil && record.kind != .upload ? .failed : .retryWaiting
            record.errorCode = resumeData == nil ? "resume_data_unavailable" : "transport_retryable"
            record.retryCount += 1
        } else if status == 401 {
            record.state = .failed
            record.errorCode = "unauthorized"
        } else if let status, TransferHTTPPolicy.isRetryable(status) {
            record.state = .retryWaiting
            record.errorCode = "http_retryable"
            record.retryCount += 1
            record.nextRetryAt = Date().addingTimeInterval(min(pow(2, Double(record.retryCount)), 300)).timeIntervalSince1970
        } else if let status, !(200...299).contains(status) {
            record.state = .failed
            record.errorCode = "http_\(status)"
        } else if record.kind != .upload,
                  let temporary = lock.withLock({ downloadLocations.removeValue(forKey: task.taskIdentifier) }) {
            do {
                guard let destinationPath = record.destinationFilePath else { throw TransferError.missingFile }
                let destination = URL(fileURLWithPath: destinationPath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: temporary, to: destination)
                try setProtection(destination)
                record.state = .completed
            } catch {
                record.state = .failed
                record.errorCode = "destination_write_failed"
            }
        } else {
            record.state = .completed
        }
        try? await repository.update(record)
        if record.state == .completed,
           let owner = try? await repository.claimOwnerWake(transferId: record.id) {
            let waker = lock.withLock { ownerWaker }
            await waker?(owner, record.id)
        }
        if record.state == .completed || record.state == .failed || record.state == .cancelled {
            finishWaiter(record)
            if let path = record.localFilePath { try? fileManager.removeItem(atPath: path) }
        }
    }

    private func finishWaiter(_ record: TransferRecord) {
        let waiter = lock.withLock { waiters.removeValue(forKey: record.id) }
        do { waiter?.resume(returning: try terminalResult(record)) }
        catch { waiter?.resume(throwing: error) }
    }

    private func terminalResult(_ record: TransferRecord) throws -> TransferRecord {
        switch record.state {
        case .completed: return record
        case .cancelled: throw TransferError.cancelled
        default: throw TransferError.failed(record.errorCode ?? "Transfer failed")
        }
    }

    private func makeRecord(kind: TransferKind, remoteURL: URL, localFile: URL?,
                            destination: URL?, ownerJobId: String?) -> TransferRecord {
        let now = Date().timeIntervalSince1970
        return TransferRecord(id: UUID().uuidString, kind: kind, state: .staged,
                              remoteURL: remoteURL.absoluteString, localFilePath: localFile?.path,
                              destinationFilePath: destination?.path, taskIdentifier: nil,
                              ownerJobId: ownerJobId, ownerWakeDelivered: false,
                              responseBody: nil, resumeData: nil, retryCount: 0,
                              nextRetryAt: nil, httpStatus: nil, errorCode: nil,
                              createdAt: now, updatedAt: now)
    }

    private func stageMultipart(data: Data, filename: String, mimeType: String,
                                boundary: String) throws -> URL {
        let directory = try transferDirectory()
        let url = directory.appendingPathComponent("\(UUID().uuidString).multipart")
        guard fileManager.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw TransferError.failed("Could not stage upload file")
        }
        defer { try? handle.close() }
        // Write each multipart segment directly to the protected backing file;
        // never materialize a second, complete multipart Data value in memory.
        try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
        try handle.write(contentsOf: Data(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8
        ))
        try handle.write(contentsOf: Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        try handle.write(contentsOf: data)
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        try setProtection(url)
        return url
    }

    private func protectAndAdopt(_ source: URL) throws -> URL {
        let directory = try transferDirectory()
        if source.deletingLastPathComponent() == directory {
            try setProtection(source)
            return source
        }
        let target = directory.appendingPathComponent("\(UUID().uuidString)-\(source.lastPathComponent)")
        try fileManager.copyItem(at: source, to: target)
        try setProtection(target)
        return target
    }

    private func transferDirectory() throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("HermesMobile/Transfers", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try setProtection(directory)
        return directory
    }

    private func setProtection(_ url: URL) throws {
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: url.path)
    }

    private func currentHeaders(for record: TransferRecord) async -> [String: String] {
        let provider = lock.withLock { headerProvider }
        return await provider(record)
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func completionProcessingFinished() {
        let completions = lock.withLock { () -> [() -> Void] in
            pendingCompletionProcessing -= 1
            guard pendingCompletionProcessing == 0, backgroundEventsFinished else { return [] }
            backgroundEventsFinished = false
            defer { backgroundCompletions.removeAll() }
            return backgroundCompletions
        }
        guard !completions.isEmpty else { return }
        Task { @MainActor in completions.forEach { $0() } }
    }

    private func drainBackgroundCompletionsIfReady() {
        let completions = lock.withLock { () -> [() -> Void] in
            guard pendingCompletionProcessing == 0, backgroundEventsFinished else { return [] }
            backgroundEventsFinished = false
            defer { backgroundCompletions.removeAll() }
            return backgroundCompletions
        }
        guard !completions.isEmpty else { return }
        Task { @MainActor in completions.forEach { $0() } }
    }
}

extension TransferManager: URLSessionDataDelegate, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { responseBodies[dataTask.taskIdentifier, default: Data()].append(data) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The callback location is temporary but remains valid through completion handling.
        lock.withLock { downloadLocations[downloadTask.taskIdentifier] = location }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.withLock { pendingCompletionProcessing += 1 }
        Task {
            await processCompletion(task: task, error: error)
            completionProcessingFinished()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task {
            await reconcile()
            lock.withLock { backgroundEventsFinished = true }
            drainBackgroundCompletionsIfReady()
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
