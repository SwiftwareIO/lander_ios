import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Sends one HTTP request. `URLSession` in apps, a fake in tests.
protocol LanderTransport: Sendable {
  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: LanderTransport {
  let session: URLSession

  init(session: URLSession = URLSessionTransport.makeSession()) {
    self.session = session
  }

  /// An ephemeral session: no cookies, no cache, nothing written to disk.
  static func makeSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.waitsForConnectivity = false
    config.httpCookieStorage = nil
    config.urlCache = nil
    return URLSession(configuration: config)
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (data, http)
  }
}

/// Exponential backoff with jitter: `base * 2^attempt`, capped at `max`.
struct Backoff: Sendable {
  var base: TimeInterval = 1
  var max: TimeInterval = 300

  /// Fraction of the delay that is randomized, between 0 and 1.
  var jitter: Double = 0.2

  /// Delay in seconds before retry number `attempt` (0 based).
  func delay(_ attempt: Int, random: Double = .random(in: 0..<1)) -> TimeInterval {
    let exp = base * pow(2, Double(Swift.min(attempt, 20)))
    let capped = Swift.min(exp, max)
    guard jitter > 0 else { return capped }
    // Spread over [capped * (1 - jitter), capped].
    return capped * (1 - jitter * random)
  }
}

/// Thin JSON client for the `/v1/sdk/*` endpoints in docs/API.md.
struct LanderAPI: Sendable {
  let apiKey: String
  let baseURL: String
  let transport: any LanderTransport
  let logger: LanderLogger

  /// Per attempt request timeout, in seconds.
  var timeout: TimeInterval = 10

  /// Backoff between attempts of ``post(_:_:idempotencyKey:maxAttempts:)``.
  var backoff = Backoff(base: 0.5, max: 4)

  /// Total time one ``post(_:_:idempotencyKey:maxAttempts:)`` may wait between its attempts.
  /// Callers are waiting on the answer (a share button, the first screen), so a longer
  /// `Retry-After` ends the retries and the error, with its `retryAfter`, goes to the caller.
  var maxRetryWait: TimeInterval = 10

  init(
    apiKey: String, baseURL: URL, transport: any LanderTransport, logger: LanderLogger,
    timeout: TimeInterval = 10, backoff: Backoff = Backoff(base: 0.5, max: 4),
    maxRetryWait: TimeInterval = 10
  ) {
    self.apiKey = apiKey
    var base = baseURL.absoluteString
    while base.hasSuffix("/") { base.removeLast() }
    self.baseURL = base
    self.transport = transport
    self.logger = logger
    self.timeout = timeout
    self.backoff = backoff
    self.maxRetryWait = maxRetryWait
  }

  /// POSTs `body` as JSON and returns the decoded response object.
  ///
  /// Retries retryable failures (network errors, timeouts, 408, 429, 5xx) up to `maxAttempts`
  /// times, reusing the same `idempotencyKey` so the server can drop duplicates, and waiting at
  /// most ``maxRetryWait`` in total. A 2xx response must be a JSON object (except 204). Throws
  /// ``LanderError`` on failure.
  func post(
    _ path: String, _ body: [String: JSONValue], idempotencyKey: String? = nil,
    maxAttempts: Int = 1
  ) async throws -> [String: JSONValue] {
    var attempt = 0
    var waited: TimeInterval = 0
    while true {
      do {
        return try await postOnce(path, body, idempotencyKey: idempotencyKey)
      } catch let error as LanderError {
        attempt += 1
        if !error.isRetryable || attempt >= maxAttempts { throw error }
        var wait = backoff.delay(attempt - 1)
        if let retryAfter = error.retryAfter, retryAfter > wait { wait = retryAfter }
        if waited + wait > maxRetryWait {
          logger.log("POST \(path) failed (\(error.code)), not retrying: next try in \(Int(wait))s")
          throw error
        }
        waited += wait
        logger.log("POST \(path) failed (\(error.code)), retrying in \(Int(wait * 1000)) ms")
        try? await Task.sleep(nanoseconds: nanoseconds(wait))
      }
    }
  }

  private func postOnce(
    _ path: String, _ body: [String: JSONValue], idempotencyKey: String?
  ) async throws -> [String: JSONValue] {
    guard let url = URL(string: baseURL + path) else {
      throw LanderError.invalidArgument("Invalid base URL")
    }
    var request = URLRequest(url: url, timeoutInterval: timeout + 5)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("ios/\(landerSDKVersion)", forHTTPHeaderField: "X-Lander-Sdk")
    if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
    do {
      request.httpBody = try JSONValue.object(body).encoded()
    } catch {
      throw LanderError.invalidArgument("POST \(path): the body cannot be encoded as JSON")
    }

    let data: Data
    let response: HTTPURLResponse
    do {
      (data, response) = try await send(request)
    } catch is TimedOut {
      throw LanderError(code: "timeout", message: "POST \(path) timed out after \(Int(timeout))s")
    } catch {
      throw LanderError(code: "network_error", message: "POST \(path) failed: \(error.localizedDescription)")
    }

    let status = response.statusCode
    let json = JSONValue.decode(data)?.object
    if (200..<300).contains(status) {
      if let json { return json }
      if status == 204 { return [:] }
      // For example a captive portal or proxy page. Treating it as success would, for init,
      // mark the first launch reported and lose a deferred link.
      throw LanderError(
        code: "invalid_response", message: "POST \(path) returned \(status) without a JSON object",
        statusCode: status)
    }
    let error = json?["error"]?.object
    throw LanderError(
      code: error?["code"]?.string ?? "http_\(status)",
      message: error?["message"]?.string ?? "POST \(path) returned \(status)",
      statusCode: status,
      retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"))
    )
  }

  private struct TimedOut: Error {}

  /// Runs the request with a hard per attempt timeout, whatever the transport does.
  private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let transport = self.transport
    let timeout = self.timeout
    return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
      group.addTask { try await transport.send(request) }
      group.addTask {
        try await Task.sleep(nanoseconds: nanoseconds(timeout))
        throw TimedOut()
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else { throw TimedOut() }
      return first
    }
  }

  static func retryAfter(_ header: String?) -> TimeInterval? {
    guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)) else {
      return nil
    }
    return TimeInterval(Swift.min(Swift.max(seconds, 0), 3600))
  }
}
