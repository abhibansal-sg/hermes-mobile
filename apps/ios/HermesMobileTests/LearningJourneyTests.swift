import XCTest
@testable import HermesMobile

final class LearningJourneyPayloadTests: XCTestCase {
    func testLearningFramesDecodeRepresentativeServerPayload() throws {
        let frame = try JSONDecoder().decode(JSONRPCInboundFrame.self, from: Data(Self.framesRPC.utf8))
        let response = try XCTUnwrap(frame.result?.decoded(as: LearningFramesResponse.self))

        XCTAssertEqual(response.count, 2)
        XCTAssertEqual(response.summary.first, "1 learned skills · 1 memories · 0 skill links")
        XCTAssertEqual(response.axis?.start, "1 Jan 2026")
        XCTAssertEqual(response.legend.map(\.glyph), ["●", "◆"])
        XCTAssertEqual(response.frames.count, 2)
        XCTAssertEqual(response.frames.first?.grid.first?.first?.text, "1 Jan ")
        XCTAssertEqual(response.frames.first?.grid.first?.first?.style, "label")
        XCTAssertEqual(response.frames.first?.grid.first?.first?.alpha, 0.74)
        XCTAssertEqual(response.frames.first?.grid.first?.first?.hexOverride, "#FFD700")
        XCTAssertEqual(response.buckets?.count, 1)
        XCTAssertEqual(response.buckets?.first?.nodes.map(\.id), ["skill-one", "memory:memory:0"])

        let journey = response.journeyData
        XCTAssertEqual(journey.items.map(\.id), ["memory:memory:0", "skill-one"])
        XCTAssertEqual(journey.items.first?.node.kindLabel, "Memory")
    }

    func testLearningDetailDecodeRepresentativeServerPayload() throws {
        let frame = try JSONDecoder().decode(JSONRPCInboundFrame.self, from: Data(Self.detailRPC.utf8))
        let detail = try XCTUnwrap(frame.result?.decoded(as: LearningNodeDetail.self))

        XCTAssertTrue(detail.ok)
        XCTAssertEqual(detail.kind, "memory")
        XCTAssertEqual(detail.id, "memory:memory:0")
        XCTAssertEqual(detail.label, "Abhi prefers concise handoffs")
        XCTAssertEqual(detail.content, "Abhi prefers concise handoffs with evidence.")
    }

    private static let framesRPC = #"""
    {
      "jsonrpc": "2.0",
      "id": "r1",
      "result": {
        "frames": [
          {
            "reveal": 0,
            "date": "1 Jan 2026",
            "visible": 1,
            "grid": [[["1 Jan ", "label", 0.74, "#FFD700"], ["●", "skill", 0.9]]],
            "labels": [{"key": "1", "glyph": "●", "label": "skill-one", "meta": "devops · 1 Jan 2026", "style": "skill", "alpha": 0.9}]
          },
          {
            "reveal": 1,
            "date": "2 Jan 2026",
            "visible": 2,
            "grid": [[["2 Jan ", "label", 0.95], ["◆", "memory", 1.0, null]]],
            "labels": []
          }
        ],
        "legend": [
          {"glyph": "●", "style": "skill", "label": "skills (1)"},
          {"glyph": "◆", "style": "memory", "label": "memories (1)"}
        ],
        "categories": [{"glyph": "●", "color": "#FFD700", "label": "devops (1)"}],
        "buckets": [
          {
            "index": 0,
            "label": "Jan 2026",
            "date": "1 Jan 2026",
            "skills": 1,
            "memories": 1,
            "total": 2,
            "category": "devops",
            "color": "#FFD700",
            "nodes": [
              {"id": "skill-one", "glyph": "●", "label": "skill-one", "fullLabel": "skill-one", "meta": "devops · 1 Jan 2026", "style": "skill"},
              {"id": "memory:memory:0", "glyph": "◆", "label": "Abhi prefers concise handoffs", "fullLabel": "Abhi prefers concise handoffs", "meta": "memory · 2 Jan 2026", "body": "Abhi prefers concise handoffs with evidence.", "style": "memory"}
            ]
          }
        ],
        "summary": ["1 learned skills · 1 memories · 0 skill links"],
        "axis": {"start": "1 Jan 2026", "end": "2 Jan 2026"},
        "count": 2,
        "cols": 80,
        "rows": 18
      }
    }
    """#

    private static let detailRPC = #"""
    {
      "jsonrpc": "2.0",
      "id": "r2",
      "result": {
        "ok": true,
        "kind": "memory",
        "id": "memory:memory:0",
        "label": "Abhi prefers concise handoffs",
        "content": "Abhi prefers concise handoffs with evidence."
      }
    }
    """#
}
