import Foundation

/// A minimal `Codable` JSON value — the wire shape for tool input schemas (sent to
/// the model) and tool-call inputs (received back). Hand-rolled because tool
/// schemas are arbitrary JSON and `Any` isn't `Sendable`/`Equatable`; this keeps
/// `ModelTool` / `ModelToolCall` value types (STYLE: structs by default).
public enum JSONValue: Sendable, Equatable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// The string at `key` when this is an object holding a string there — the
  /// common case for reading a tool-call argument.
  public func string(_ key: String) -> String? {
    guard case let .object(fields) = self, case let .string(value)? = fields[key] else {
      return nil
    }
    return value
  }

  /// The bool at `key`, when present and boolean.
  public func bool(_ key: String) -> Bool? {
    guard case let .object(fields) = self, case let .bool(value)? = fields[key] else {
      return nil
    }
    return value
  }
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
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
        in: container, debugDescription: "Unrecognized JSON value")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case let .bool(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .string(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    }
  }
}

extension JSONValue: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { first, _ in first }))
  }
}

extension JSONValue: ExpressibleByArrayLiteral {
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
