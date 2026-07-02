import Foundation

/// `learning.frames` returns a pre-rendered learning timeline plus the bucket
/// metadata needed for a native mobile list. The server builds this from
/// `agent.learning_graph_render.render_frames`.
struct LearningFramesResponse: Decodable, Equatable, Sendable {
    let frames: [LearningTimelineFrame]
    let legend: [LearningLegendItem]
    let categories: [LearningLegendItem]?
    let buckets: [LearningTimelineBucket]?
    let summary: [String]
    let axis: LearningTimelineAxis?
    let count: Int
    let cols: Int?
    let rows: Int?
}

struct LearningTimelineFrame: Decodable, Equatable, Sendable {
    let reveal: Double?
    let date: String?
    let visible: Int?
    let grid: [[LearningRenderRun]]
    let labels: [LearningFrameLabel]?
}

/// One terminal-style render run: `[text, style, alpha, hexOverride?]`.
struct LearningRenderRun: Decodable, Equatable, Sendable {
    let text: String
    let style: String
    let alpha: Double?
    let hexOverride: String?

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        text = try container.decode(String.self)
        style = try container.decode(String.self)
        alpha = container.isAtEnd ? nil : try container.decodeIfPresent(Double.self)
        hexOverride = container.isAtEnd ? nil : try container.decodeIfPresent(String.self)
    }
}

struct LearningFrameLabel: Decodable, Equatable, Sendable {
    let key: String?
    let glyph: String?
    let label: String
    let meta: String?
    let style: String?
    let alpha: Double?
}

struct LearningLegendItem: Decodable, Equatable, Sendable {
    let glyph: String
    let style: String?
    let color: String?
    let label: String
}

struct LearningTimelineAxis: Decodable, Equatable, Sendable {
    let start: String
    let end: String
}

struct LearningTimelineBucket: Decodable, Equatable, Sendable, Identifiable {
    let index: Int
    let label: String
    let date: String
    let skills: Int
    let memories: Int
    let total: Int?
    let category: String?
    let color: String?
    let nodes: [LearningBucketNode]

    var id: Int { index }
}

struct LearningBucketNode: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let glyph: String
    let label: String
    let fullLabel: String?
    let meta: String
    let body: String?
    let style: String

    var isMemory: Bool { style == "memory" || id.hasPrefix("memory:") }
    var kindLabel: String { isMemory ? "Memory" : "Skill" }
}

struct LearningJourneyData: Equatable, Sendable {
    let summary: [String]
    let axis: LearningTimelineAxis?
    let items: [LearningJourneyItem]
}

struct LearningJourneyItem: Identifiable, Equatable, Sendable {
    let id: String
    let bucketLabel: String
    let bucketDate: String
    let bucketColor: String?
    let node: LearningBucketNode

    var title: String { node.fullLabel?.isEmpty == false ? node.fullLabel! : node.label }
    var subtitle: String { "\(node.kindLabel) · \(node.meta)" }
}

struct LearningNodeDetail: Decodable, Equatable, Sendable {
    let ok: Bool
    let kind: String?
    let id: String?
    let label: String?
    let content: String?
    let message: String?
}

extension LearningFramesResponse {
    /// Native iOS v1 lists bucket nodes newest-first. Server buckets are emitted
    /// oldest → newest for the terminal scrubber, so reverse both dimensions.
    var journeyData: LearningJourneyData {
        let items = (buckets ?? [])
            .reversed()
            .flatMap { bucket in
                bucket.nodes.reversed().map { node in
                    LearningJourneyItem(
                        id: node.id,
                        bucketLabel: bucket.label,
                        bucketDate: bucket.date,
                        bucketColor: bucket.color,
                        node: node
                    )
                }
            }
        return LearningJourneyData(summary: summary, axis: axis, items: items)
    }
}
