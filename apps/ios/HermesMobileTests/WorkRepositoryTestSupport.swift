import Foundation

func makeWorkRepositoryTestConfiguration(
    protectedDataAvailable: @escaping @Sendable () -> Bool = { true }
) throws -> (configuration: WorkRepositoryConfiguration, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkRepositoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (
        WorkRepositoryConfiguration(
            containerURL: directory,
            protectedDataAvailable: protectedDataAvailable
        ),
        directory
    )
}

func workTestScope(
    serverID: String = "https://gateway.example",
    profileID: String = "default"
) throws -> WorkScope {
    try WorkScope(serverID: serverID, profileID: profileID)
}
