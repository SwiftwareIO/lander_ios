import Foundation

/// A JSON value. Request bodies, responses and the persisted event queue go through this type,
/// so everything the SDK moves between tasks is `Sendable`.
enum JSONValue: Sendable, Hashable, Codable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .int(let value): try container.encode(value)
    case .double(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  /// Decodes `data`, or returns nil when it is not JSON.
  static func decode(_ data: Data) -> JSONValue? {
    guard !data.isEmpty else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: data)
  }

  func encoded() throws -> Data { try JSONEncoder().encode(self) }

  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var object: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var array: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  subscript(key: String) -> JSONValue? { object?[key] }

  /// Converts a value from app code (event properties) to JSON. Accepts strings, booleans,
  /// numbers, nil, and arrays and string keyed dictionaries of those.
  static func from(any value: Any) throws -> JSONValue {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      guard let wrapped = mirror.children.first?.value else { return .null }
      return try from(any: wrapped)
    }
    switch value {
    case is NSNull: return .null
    case let value as String: return .string(value)
    case let value as Substring: return .string(String(value))
    case let value as Character: return .string(String(value))
    case let value as Bool where type(of: value) == Bool.self: return .bool(value)
    case let value as any BinaryInteger:
      guard let int = Int(exactly: value) else { return .double(Double(value)) }
      return .int(int)
    case let value as any BinaryFloatingPoint:
      let double = Double(value)
      guard double.isFinite else { throw UnsupportedValue(value: "\(value)") }
      return .double(double)
    case let value as Decimal:
      return .double(NSDecimalNumber(decimal: value).doubleValue)
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
      let type = String(cString: value.objCType)
      if type == "f" || type == "d" {
        guard value.doubleValue.isFinite else { throw UnsupportedValue(value: "\(value)") }
        return .double(value.doubleValue)
      }
      return .int(value.intValue)
    case let value as [Any]:
      return .array(try value.map { try from(any: $0) })
    case let value as [String: Any]:
      return .object(try value.mapValues { try from(any: $0) })
    case let value as LanderParamValue:
      return value.json
    default:
      throw UnsupportedValue(value: "\(type(of: value))")
    }
  }

  struct UnsupportedValue: Error {
    let value: String
  }
}
