import XCTest
@testable import HermesMobile

/// Coverage for the F3 draft-greeting composition (Amendment E): the time-aware
/// phrase mapping and — explicitly required — the period fallback when no display
/// name is set ("Morning." / "Evening.").
final class GreetingTests: XCTestCase {

    // MARK: - Time-of-day phrase

    private func phrase(at hour: Int) -> String {
        var components = DateComponents()
        components.year = 2026
        components.month = 6
        components.day = 5
        components.hour = hour
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: components)!
        return ChatView.timeOfDayPhrase(date, calendar: calendar)
    }

    func testMorningPhrase() {
        XCTAssertEqual(phrase(at: 5), "Morning")
        XCTAssertEqual(phrase(at: 9), "Morning")
        XCTAssertEqual(phrase(at: 11), "Morning")
    }

    func testAfternoonPhrase() {
        XCTAssertEqual(phrase(at: 12), "Afternoon")
        XCTAssertEqual(phrase(at: 16), "Afternoon")
    }

    func testEveningPhrase() {
        XCTAssertEqual(phrase(at: 17), "Evening")
        XCTAssertEqual(phrase(at: 23), "Evening")
        XCTAssertEqual(phrase(at: 0), "Evening")
        XCTAssertEqual(phrase(at: 4), "Evening")
    }

    // MARK: - Greeting composition

    func testGreetingWithNameUsesComma() {
        XCTAssertEqual(ChatView.greeting(phrase: "Evening", name: "Abhinav"), "Evening, Abhinav")
        XCTAssertEqual(ChatView.greeting(phrase: "Morning", name: "Sam"), "Morning, Sam")
    }

    /// Amendment E (explicit): with the display name unset the greeting is the
    /// bare time word with a trailing period.
    func testGreetingFallbackHasPeriod() {
        XCTAssertEqual(ChatView.greeting(phrase: "Morning", name: nil), "Morning.")
        XCTAssertEqual(ChatView.greeting(phrase: "Evening", name: nil), "Evening.")
    }

    /// A blank/empty name is treated as unset → period fallback (not a dangling
    /// "Evening, ").
    func testGreetingEmptyNameFallsBackToPeriod() {
        XCTAssertEqual(ChatView.greeting(phrase: "Afternoon", name: ""), "Afternoon.")
    }
}
