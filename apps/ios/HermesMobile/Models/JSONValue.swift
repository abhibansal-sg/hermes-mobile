import Foundation

/// A type-safe representation of any JSON value, used for JSON-RPC params,
/// results, and event payloads whose shape varies by method/event type.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Encode whole numbers without a trailing ".0" so server-side
            // integer params (cols, limit, ordinals) round-trip cleanly.
            if value.truncatingRemainder(dividingBy: 1) == 0,
               value >= Double(Int64.min), value <= Double(Int64.max) {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Literal conveniences

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral {
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// MARK: - Accessors

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// String value tolerant of a numeric scalar (H3 correlation guard). The
    /// gateway is expected to send `stored_session_id` as a JSON string, but a
    /// numeric stored id (or one a future server serializes as a number) would
    /// otherwise coerce to `nil` via ``stringValue`` and silently zero the
    /// mirror correlation. A whole number renders without a trailing ".0" so it
    /// round-trips to the same id the server stored; a true `nil`/null/bool/
    /// array/object still yields `nil`.
    var coercedStringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.truncatingRemainder(dividingBy: 1) == 0,
               value >= Double(Int64.min), value <= Double(Int64.max) {
                return String(Int64(value))
            }
            return String(value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// Re-decode this JSON value into a concrete `Decodable` type.
    /// Keys are converted from snake_case to camelCase, matching the
    /// hermes gateway wire format.
    func decoded<T: Decodable>(as type: T.Type = T.self) -> T? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(T.self, from: data)
    }

    /// Render a compact human-readable preview (used for tool args/results).
    var compactDescription: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            if value.truncatingRemainder(dividingBy: 1) == 0 { return String(Int(value)) }
            return String(value)
        case .string(let value): return value
        case .array(let value):
            return "[" + value.map(\.compactDescription).joined(separator: ", ") + "]"
        case .object(let value):
            let pairs = value
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.compactDescription)" }
            return "{" + pairs.joined(separator: ", ") + "}"
        }
    }
}
