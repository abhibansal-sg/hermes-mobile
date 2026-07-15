enum TransferHTTPPolicy {
    static func isRetryable(_ status: Int) -> Bool {
        [408, 429, 500, 502, 503, 504].contains(status)
    }
}
