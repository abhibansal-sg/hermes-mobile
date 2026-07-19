import Foundation

/// HRP/2 requests carry signatures, App Attest objects, APNs tokens, or
/// one-time pairing capabilities. Never replay any of them through an HTTP
/// redirect, even when URLSession considers the redirect otherwise safe.
final class RelayV2NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
