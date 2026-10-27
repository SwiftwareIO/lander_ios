import Foundation

/// How sure Lander is that a link caused this open or install.
public enum LanderConfidence: String, Sendable, Hashable, Codable, CaseIterable {
  /// Matched by an exact identifier, for example a Universal Link open, the Continue in app page
  /// or an authenticated handoff.
  case deterministic

  /// Matched by coarse signals (OS version, country, click time) within a short window. Only for
  /// iOS deferred links of projects that opted in.
  case probabilistic

  /// No link could be tied to this open.
  case unattributed

  static func parse(_ value: JSONValue?) -> LanderConfidence {
    value?.string.flatMap(LanderConfidence.init(rawValue:)) ?? .unattributed
  }
}

/// A link parameter value: a string, a number or a boolean, as the API stores them.
///
/// Literals convert on their own, so `["productId": "123", "qty": 2, "gift": true]` is a
/// `[String: LanderParamValue]`.
public enum LanderParamValue: Sendable, Hashable, CustomStringConvertible,
  ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
  ExpressibleByBooleanLiteral
{
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)

  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }

  /// The value as text: strings as they are, numbers and booleans in their JSON form.
  public var stringValue: String {
    switch self {
    case .string(let value): return value
    case .int(let value): return String(value)
    case .double(let value):
      return value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
    case .bool(let value): return value ? "true" : "false"
    }
  }

  /// The value as an integer, when it is one (or a string holding one).
  public var intValue: Int? {
    switch self {
    case .int(let value): return value
    case .double(let value): return Int(exactly: value)
    case .string(let value): return Int(value)
    case .bool: return nil
    }
  }

  /// The value as a number, when it is one (or a string holding one).
  public var doubleValue: Double? {
    switch self {
    case .int(let value): return Double(value)
    case .double(let value): return value
    case .string(let value): return Double(value)
    case .bool: return nil
    }
  }

  /// The value as a boolean, when it is one (or the string `true` or `false`).
  public var boolValue: Bool? {
    switch self {
    case .bool(let value): return value
    case .string("true"): return true
    case .string("false"): return false
    default: return nil
    }
  }

  public var description: String { stringValue }

  var json: JSONValue {
    switch self {
    case .string(let value): return .string(value)
    case .int(let value): return .int(value)
    case .double(let value): return .double(value)
    case .bool(let value): return .bool(value)
    }
  }

  init?(json: JSONValue) {
    switch json {
    case .string(let value): self = .string(value)
    case .int(let value): self = .int(value)
    case .double(let value): self = .double(value)
    case .bool(let value): self = .bool(value)
    default: return nil
    }
  }

  static func params(_ json: JSONValue?) -> [String: LanderParamValue] {
    guard let object = json?.object else { return [:] }
    return object.compactMapValues(LanderParamValue.init(json:))
  }
}

/// A deep link delivered to the app.
///
/// When Lander knows the link, the fields mirror the `ResolvedLink` returned by
/// `POST /v1/sdk/resolve`. When it does not (unknown link, custom scheme URL, or the network was
/// unavailable) only ``url`` is set, ``isResolved`` is false and the app can still route on the
/// raw URL with ``route``.
public struct LanderLink: Sendable, Hashable, CustomStringConvertible {
  /// The URL that opened the app, exactly as iOS delivered it. For a deferred link it is the
  /// link's short URL.
  public let url: URL

  /// Lander link ID, or nil when the link is not known to Lander.
  public let linkId: String?

  /// The canonical short link, for example `https://acme.golander.link/p-123`.
  public let shortURL: URL?

  /// The in app route configured on the link, for example `/product/123`.
  public let path: String?

  /// The link's stored params with the opened URL's query parameters merged over them.
  public let params: [String: LanderParamValue]

  public let campaign: String?
  public let channel: String?

  /// True when the link was recovered after an install or handed off after sign in (a deferred
  /// deep link), rather than opened directly.
  public let isDeferred: Bool

  /// How sure Lander is that this link belongs to this open or install.
  public let confidence: LanderConfidence

  /// How the link was tied to this open or install, as reported by the API:
  /// `universal_link`, `landing_page`, `authenticated_handoff` or `probabilistic_match` (and
  /// `app_link` or `install_referrer` on Android). Nil when unresolved.
  public let method: String?

  public init(
    url: URL,
    linkId: String? = nil,
    shortURL: URL? = nil,
    path: String? = nil,
    params: [String: LanderParamValue] = [:],
    campaign: String? = nil,
    channel: String? = nil,
    isDeferred: Bool = false,
    confidence: LanderConfidence = .unattributed,
    method: String? = nil
  ) {
    self.url = url
    self.linkId = linkId
    self.shortURL = shortURL
    self.path = path
    self.params = params
    self.campaign = campaign
    self.channel = channel
    self.isDeferred = isDeferred
    self.confidence = confidence
    self.method = method
  }

  /// A link Lander could not resolve. Only the raw `url` is available.
  public static func unresolved(_ url: URL) -> LanderLink { LanderLink(url: url) }

  /// Builds a link from a `ResolvedLink` JSON object. `url` is the URL that opened the app; for
  /// deferred links it falls back to the link's own URL.
  ///
  /// Never fails: fields of an unexpected type are treated as missing, so a partly malformed
  /// response still delivers what it can.
  init(json: [String: JSONValue], url opened: URL? = nil) {
    let short = json["url"]?.string.flatMap(URL.init(string:))
    self.init(
      url: opened ?? short ?? URL(string: "about:blank")!,
      linkId: json["linkId"]?.string,
      shortURL: short,
      path: json["path"]?.string,
      params: LanderParamValue.params(json["params"]),
      campaign: json["campaign"]?.string,
      channel: json["channel"]?.string,
      isDeferred: json["isDeferred"] == .bool(true),
      confidence: LanderConfidence.parse(json["confidence"]),
      method: json["method"]?.string
    )
  }

  /// Whether Lander recognized this link.
  public var isResolved: Bool { linkId != nil }

  /// The route to navigate to: the link's ``path`` when resolved, otherwise the raw URL's path
  /// and query. For custom scheme URLs the host counts as the first path segment, so
  /// `acmeshop://product/123` gives `/product/123`.
  public var route: String {
    if let path { return path }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      return "/"
    }
    let scheme = components.scheme?.lowercased()
    let isWeb = scheme == "http" || scheme == "https"
    let host = components.host?.lowercased() ?? ""
    var raw =
      !isWeb && !host.isEmpty
      ? "/\(host)\(components.percentEncodedPath)" : components.percentEncodedPath
    if raw.isEmpty { raw = "/" }
    if let query = components.percentEncodedQuery { return "\(raw)?\(query)" }
    return raw
  }

  public var description: String {
    guard isResolved else { return "LanderLink(unresolved, url: \(url))" }
    let params = self.params.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
    return
      "LanderLink(\(linkId ?? ""), path: \(path ?? "nil"), params: [\(params.joined(separator: ", "))], url: \(url)"
      + "\(isDeferred ? ", deferred" : ""), \(confidence.rawValue)\(method.map { " via \($0)" } ?? ""))"
  }
}

/// A short link created with
/// ``Lander/createLink(path:params:title:campaign:channel:tags:iosFallbackURL:androidFallbackURL:webFallbackURL:ogTitle:ogDescription:ogImageURL:expiresAt:)``.
public struct LanderShortLink: Sendable, Hashable, CustomStringConvertible {
  public let id: String

  /// The shareable URL, for example `https://acme.golander.link/x7Kp2Qa`.
  public let url: URL
  public let domain: String
  public let slug: String

  /// The in app route the link opens.
  public let path: String
  public let params: [String: LanderParamValue]
  public let title: String?
  public let campaign: String?
  public let channel: String?
  public let tags: [String]
  public let expiresAt: Date?
  public let createdAt: Date?

  public init(
    id: String, url: URL, domain: String, slug: String, path: String,
    params: [String: LanderParamValue] = [:], title: String? = nil, campaign: String? = nil,
    channel: String? = nil, tags: [String] = [], expiresAt: Date? = nil, createdAt: Date? = nil
  ) {
    self.id = id
    self.url = url
    self.domain = domain
    self.slug = slug
    self.path = path
    self.params = params
    self.title = title
    self.campaign = campaign
    self.channel = channel
    self.tags = tags
    self.expiresAt = expiresAt
    self.createdAt = createdAt
  }

  init?(json: [String: JSONValue]) {
    guard let id = json["id"]?.string, let url = json["url"]?.string.flatMap(URL.init(string:))
    else { return nil }
    self.init(
      id: id,
      url: url,
      domain: json["domain"]?.string ?? "",
      slug: json["slug"]?.string ?? "",
      path: json["deepLinkPath"]?.string ?? "/",
      params: LanderParamValue.params(json["params"]),
      title: json["title"]?.string,
      campaign: json["campaign"]?.string,
      channel: json["channel"]?.string,
      tags: json["tags"]?.array?.compactMap(\.string) ?? [],
      expiresAt: json["expiresAt"]?.string.flatMap(ISODate.parse),
      createdAt: json["createdAt"]?.string.flatMap(ISODate.parse)
    )
  }

  public var description: String { url.absoluteString }
}
