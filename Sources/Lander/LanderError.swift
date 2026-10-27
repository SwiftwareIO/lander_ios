import Foundation

/// The error thrown by Lander calls that need an answer from the API, such as
/// ``Lander/createLink(path:params:title:campaign:channel:tags:iosFallbackURL:androidFallbackURL:webFallbackURL:ogTitle:ogDescription:ogImageURL:expiresAt:)``,
/// and by ``Lander/initialize(apiKey:baseURL:enableLogging:)`` for a bad key. Fire and forget
/// calls (`initialize`'s launch report, `trackEvent`) never throw on network or server errors.
public struct LanderError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
  /// The API's error code (for example `rate_limited`), or one of the SDK's own codes:
  /// `network_error`, `timeout` and `invalid_response` for client side failures,
  /// `invalid_argument` for a bad argument, `not_initialized` before
  /// ``Lander/initialize(apiKey:baseURL:enableLogging:)`` and `install_not_registered` when
  /// the install could not be registered with the API yet.
  public let code: String

  /// A human readable explanation. Never contains the API key.
  public let message: String

  /// HTTP status, or nil when no response was received.
  public let statusCode: Int?

  /// Server requested delay before retrying, in seconds, from the `Retry-After` header.
  public let retryAfter: TimeInterval?

  public init(code: String, message: String, statusCode: Int? = nil, retryAfter: TimeInterval? = nil) {
    self.code = code
    self.message = message
    self.statusCode = statusCode
    self.retryAfter = retryAfter
  }

  /// Whether retrying the same request later may succeed.
  ///
  /// `link_quota_exceeded` is a 429 but frees up only as the rolling 24 hour window moves, so
  /// retrying soon cannot help. `invalid_response` usually comes from something between the app
  /// and Lander (a captive portal).
  public var isRetryable: Bool {
    if code == "link_quota_exceeded" || code == "invalid_argument" || code == "not_initialized" {
      return false
    }
    if code == "invalid_response" { return true }
    guard let status = statusCode else { return true }
    return status == 408 || status == 429 || status >= 500
  }

  public var description: String {
    "LanderError(\(code)\(statusCode.map { ", \($0)" } ?? "")): \(message)"
  }

  public var errorDescription: String? { message }

  static func invalidArgument(_ message: String) -> LanderError {
    LanderError(code: "invalid_argument", message: message)
  }

  static func notInitialized(_ method: String) -> LanderError {
    LanderError(
      code: "not_initialized", message: "Call Lander.initialize(apiKey:) before Lander.\(method)")
  }
}
