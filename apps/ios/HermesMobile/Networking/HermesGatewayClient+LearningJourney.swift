import Foundation

extension HermesGatewayClient {
    /// `learning.frames` → read-only Learning Journey timeline.
    func learningFrames(cols: Int = 80, rows: Int = 18, frames: Int = 2) async throws -> LearningFramesResponse {
        try await request(
            "learning.frames",
            params: .object([
                "cols": .number(Double(cols)),
                "rows": .number(Double(rows)),
                "frames": .number(Double(frames)),
            ]),
            timeout: .seconds(30)
        )
    }

    /// `learning.detail {id}` → current content for a timeline node.
    func learningDetail(id: String) async throws -> LearningNodeDetail {
        try await request(
            "learning.detail",
            params: .object(["id": .string(id)]),
            timeout: .seconds(30)
        )
    }
}
