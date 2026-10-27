import Foundation

@testable import Lander

/// In memory stand in for the OS.
final class FakePlatform: LanderPlatform, @unchecked Sendable {
  private let lock = NSLock()
  private var _storage: [String: String]
  private var _writeFailures: [String: Int] = [:]
  let info: LanderPlatformInfo
  let lifecycle = AsyncStream.makeStream(of: LanderLifecycleEvent.self)

  init(
    platform: String = "ios", appVersion: String = "2.4.0", osVersion: String = "18.1",
    storage: [String: String] = [:]
  ) {
    info = LanderPlatformInfo(platform: platform, appVersion: appVersion, osVersion: osVersion)
    _storage = storage
  }

  var storage: [String: String] {
    lock.lock()
    defer { lock.unlock() }
    return _storage
  }

  /// Makes the next `count` writes to `key` fail.
  func failWrites(_ key: String, count: Int) {
    lock.lock()
    _writeFailures[key] = count
    lock.unlock()
  }

  func platformInfo() -> LanderPlatformInfo { info }

  func read(_ key: String) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return _storage[key]
  }

  struct DiskFull: Error {}

  func write(_ key: String, _ value: String) throws {
    lock.lock()
    defer { lock.unlock() }
    if let failures = _writeFailures[key], failures > 0 {
      _writeFailures[key] = failures - 1
      throw DiskFull()
    }
    _storage[key] = value
  }

  func delete(_ key: String) throws {
    lock.lock()
    _storage[key] = nil
    lock.unlock()
  }

  func lifecycleEvents() -> AsyncStream<LanderLifecycleEvent> { lifecycle.stream }

  func send(_ event: LanderLifecycleEvent) { lifecycle.continuation.yield(event) }
}

/// A recorded request with its decoded JSON body.
struct Recorded: Sendable {
  let path: String
  let headers: [String: String]
  let body: [String: JSONValue]

  func header(_ name: String) -> String? {
    headers.first { $0.key.lowercased() == name.lowercased() }?.value
  }
}

struct FakeResponse: Sendable {
  var status: Int
  var body: Data
  var headers: [String: String] = [:]
}

struct Offline: Error {}

typealias Handler = @Sendable (Recorded) async throws -> FakeResponse

/// A transport that records requests and answers per path.
final class FakeTransport: LanderTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var handlers: [String: Handler]
  private var _requests: [Recorded] = []

  static let defaultHandlers: [String: Handler] = [
    "/v1/sdk/init": { r in json(["installId": r.body["installId"] ?? .null, "deferredLink": .null]) },
    "/v1/sdk/resolve": { _ in apiError("link_not_found", 404) },
    "/v1/sdk/events": { r in
      json(["accepted": .int(r.body["events"]?.array?.count ?? 0), "duplicates": 0], 202)
    },
  ]

  init(_ handlers: [String: Handler] = [:]) {
    self.handlers = Self.defaultHandlers.merging(handlers) { $1 }
  }

  var requests: [Recorded] {
    lock.lock()
    defer { lock.unlock() }
    return _requests
  }

  func to(_ path: String) -> [Recorded] { requests.filter { $0.path == path } }

  private func record(_ recorded: Recorded) -> Handler? {
    lock.lock()
    defer { lock.unlock() }
    _requests.append(recorded)
    return handlers[recorded.path]
  }

  func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = request.url!
    let body = request.httpBody.flatMap { JSONValue.decode($0)?.object } ?? [:]
    let recorded = Recorded(
      path: url.path, headers: request.allHTTPHeaderFields ?? [:], body: body)
    let handler = record(recorded)
    let response = try await (handler ?? { _ in apiError("not_found", 404) })(recorded)
    let http = HTTPURLResponse(
      url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
      headerFields: response.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
    return (response.body, http)
  }
}

func json(_ body: JSONValue, _ status: Int = 200, headers: [String: String] = [:]) -> FakeResponse
{
  FakeResponse(status: status, body: try! body.encoded(), headers: headers)
}

func apiError(_ code: String, _ status: Int, headers: [String: String] = [:]) -> FakeResponse {
  json(["error": ["code": .string(code), "message": "x"]], status, headers: headers)
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByDictionaryLiteral,
  ExpressibleByArrayLiteral, ExpressibleByNilLiteral
{
  public init(stringLiteral value: String) { self = .string(value) }
  public init(integerLiteral value: Int) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
  }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(nilLiteral: ()) { self = .null }
}

let resolvedP123: [String: JSONValue] = [
  "linkId": "6f1c1f9e-8a2b-4c3d-9e4f-5a6b7c8d9e0f",
  "url": "https://acme.golander.link/p-123",
  "path": "/product/123",
  "params": ["productId": "123", "utm_source": "x"],
  "campaign": nil,
  "channel": "share",
  "isDeferred": false,
  "confidence": "deterministic",
  "method": "universal_link",
]

/// What `/v1/sdk/init` returns for a first launch that recovered a deferred link.
let deferredSpring: [String: JSONValue] = [
  "linkId": "9b1f3c2e-4d5a-4b6c-8d7e-0f1a2b3c4d5e",
  "url": "https://acme.golander.link/spring-sale",
  "path": "/sale/spring",
  "params": ["discount": "15"],
  "campaign": "spring_2027",
  "channel": nil,
  "isDeferred": true,
  "confidence": "probabilistic",
  "method": "probabilistic_match",
]

extension Dictionary where Key == String, Value == JSONValue {
  func with(_ overrides: [String: JSONValue]) -> [String: JSONValue] {
    merging(overrides) { $1 }
  }
}

let testKey = "pk_test_DemoPublishableKey000000000000"

func makeClient(
  _ platform: FakePlatform, _ transport: FakeTransport,
  dispatcher: LinkDispatcher = LinkDispatcher(),
  flushDelay: TimeInterval = 0
) -> LanderClient {
  var config = LanderClientConfig(apiKey: testKey, baseURL: URL(string: "http://localhost:8787")!)
  config.flushDelay = flushDelay
  config.requestBackoff = Backoff(base: 0.001, max: 0.01, jitter: 0)
  config.eventBackoff = Backoff(base: 0.001, max: 0.01, jitter: 0)
  config.launchWindowCap = 60
  return LanderClient(
    config: config, dispatcher: dispatcher, platform: platform, transport: transport)
}

/// Starts `client` as a launch would: `launchLinks` are the URLs handed to the SDK while the
/// app launched, then the launch settles and the launch report finishes.
func started(_ client: LanderClient, launchLinks: [String] = []) async {
  for raw in launchLinks {
    await client.receive(IncomingLink(raw: raw, receivedAt: Date()))
  }
  await client.start(links: AsyncStream { _ in })
  await client.closeLaunchWindow()
  await client.initDone.wait()
  await pause()
}

/// Lets queued tasks run.
func pause(_ seconds: TimeInterval = 0.03) async {
  try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

/// Polls `condition` until it holds or `timeout` passes.
func eventually(
  timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await condition() { return true }
    await pause(0.01)
  }
  return await condition()
}

/// Collects what a stream delivers, in the background.
final class Collector<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var _items: [T] = []
  private var task: Task<Void, Never>?

  init(_ stream: AsyncStream<T>) {
    task = Task { [weak self] in
      for await item in stream { self?.append(item) }
    }
  }

  private func append(_ item: T) {
    lock.lock()
    _items.append(item)
    lock.unlock()
  }

  var items: [T] {
    lock.lock()
    defer { lock.unlock() }
    return _items
  }

  func cancel() { task?.cancel() }
}
