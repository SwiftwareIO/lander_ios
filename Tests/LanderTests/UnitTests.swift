import Foundation
import Testing

@testable import Lander

@Suite("API client")
struct APIClientTests {
  func api(_ transport: FakeTransport, maxRetryWait: TimeInterval = 10) -> LanderAPI {
    LanderAPI(
      apiKey: testKey, baseURL: URL(string: "http://localhost:8787/")!, transport: transport,
      logger: LanderLogger(enabled: false), timeout: 0.5,
      backoff: Backoff(base: 0.001, max: 0.01, jitter: 0), maxRetryWait: maxRetryWait)
  }

  @Test("sends the SDK headers and a JSON body")
  func headers() async throws {
    let transport = FakeTransport(["/v1/x": { _ in json(["ok": true]) }])
    let result = try await api(transport).post("/v1/x", ["a": 1], idempotencyKey: "k1")
    #expect(result == ["ok": true])
    let req = try #require(transport.requests.first)
    #expect(req.path == "/v1/x", "trailing slash of the base URL is dropped")
    #expect(req.header("Authorization") == "Bearer \(testKey)")
    #expect(req.header("Content-Type") == "application/json")
    #expect(req.header("X-Lander-Sdk") == "ios/\(Lander.sdkVersion)")
    #expect(req.header("Idempotency-Key") == "k1")
    #expect(req.body == ["a": 1])
  }

  @Test("retryable failures are retried with the same idempotency key")
  func retries() async throws {
    let calls = Locked(0)
    let transport = FakeTransport([
      "/v1/x": { _ in
        let n = calls.withLock { $0 += 1; return $0 }
        if n == 1 { throw Offline() }
        if n == 2 { return apiError("rate_limited", 429) }
        return json(["ok": true])
      }
    ])
    _ = try await api(transport).post("/v1/x", [:], idempotencyKey: "same", maxAttempts: 3)
    #expect(transport.requests.count == 3)
    #expect(Set(transport.requests.map { $0.header("Idempotency-Key") }) == ["same"])
  }

  @Test("client errors are not retried and carry the API's code")
  func notRetried() async throws {
    let transport = FakeTransport(["/v1/x": { _ in apiError("validation_error", 400) }])
    do {
      _ = try await api(transport).post("/v1/x", [:], maxAttempts: 3)
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "validation_error")
      #expect(error.statusCode == 400)
      #expect(!error.isRetryable)
    }
    #expect(transport.requests.count == 1)
  }

  @Test("link_quota_exceeded is not retried")
  func quota() async throws {
    let transport = FakeTransport(["/v1/x": { _ in apiError("link_quota_exceeded", 429) }])
    await #expect(throws: LanderError.self) {
      try await api(transport).post("/v1/x", [:], maxAttempts: 3)
    }
    #expect(transport.requests.count == 1)
  }

  @Test("a Retry-After beyond the total retry wait ends the retries with retryAfter set")
  func longRetryAfter() async throws {
    let transport = FakeTransport([
      "/v1/x": { _ in apiError("rate_limited", 429, headers: ["Retry-After": "30"]) }
    ])
    do {
      _ = try await api(transport).post("/v1/x", [:], maxAttempts: 3)
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "rate_limited")
      #expect(error.retryAfter == 30)
    }
    #expect(transport.requests.count == 1)
  }

  @Test("a short Retry-After is waited for")
  func shortRetryAfter() async throws {
    let calls = Locked(0)
    let transport = FakeTransport([
      "/v1/x": { _ in
        calls.withLock { $0 += 1; return $0 } == 1
          ? apiError("rate_limited", 429, headers: ["Retry-After": "1"]) : json([:])
      }
    ])
    let start = Date()
    _ = try await api(transport).post("/v1/x", [:], maxAttempts: 2)
    #expect(Date().timeIntervalSince(start) >= 0.9)
    #expect(transport.requests.count == 2)
  }

  @Test("Retry-After parsing clamps to an hour and ignores dates")
  func retryAfterParsing() {
    #expect(LanderAPI.retryAfter("5") == 5)
    #expect(LanderAPI.retryAfter(" 7 ") == 7)
    #expect(LanderAPI.retryAfter("99999") == 3600)
    #expect(LanderAPI.retryAfter("-3") == 0)
    #expect(LanderAPI.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
    #expect(LanderAPI.retryAfter(nil) == nil)
  }

  @Test("a 2xx without a JSON object is invalid_response; 204 is empty")
  func nonJSON() async throws {
    let transport = FakeTransport([
      "/v1/html": { _ in FakeResponse(status: 200, body: Data("<html>".utf8)) },
      "/v1/empty": { _ in FakeResponse(status: 204, body: Data()) },
    ])
    do {
      _ = try await api(transport).post("/v1/html", [:])
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "invalid_response")
      #expect(error.isRetryable)
    }
    #expect(try await api(transport).post("/v1/empty", [:]) == [:])
  }

  @Test("an error without a JSON body gets an http_ code")
  func httpCode() async throws {
    let transport = FakeTransport([
      "/v1/x": { _ in FakeResponse(status: 502, body: Data("Bad gateway".utf8)) }
    ])
    do {
      _ = try await api(transport).post("/v1/x", [:])
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "http_502")
      #expect(error.statusCode == 502)
    }
  }

  @Test("a request slower than the timeout fails with timeout")
  func timeout() async throws {
    let transport = FakeTransport([
      "/v1/x": { _ in
        try await Task.sleep(nanoseconds: 5_000_000_000)
        return json([:])
      }
    ])
    do {
      _ = try await api(transport).post("/v1/x", [:])
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "timeout")
    }
  }

  @Test("responses are decoded as UTF-8")
  func utf8() async throws {
    let transport = FakeTransport(["/v1/x": { _ in json(["title": "Café ünïcode"]) }])
    #expect(try await api(transport).post("/v1/x", [:])["title"] == "Café ünïcode")
  }

  @Test("backoff doubles, caps and jitters downward")
  func backoff() {
    let backoff = Backoff(base: 1, max: 5, jitter: 0)
    #expect(backoff.delay(0) == 1)
    #expect(backoff.delay(1) == 2)
    #expect(backoff.delay(2) == 4)
    #expect(backoff.delay(3) == 5)
    let jittered = Backoff(base: 1, max: 5, jitter: 0.2)
    #expect(jittered.delay(1, random: 1) == 1.6)
    #expect(jittered.delay(1, random: 0) == 2)
  }
}

@Suite("Event queue")
struct EventQueueTests {
  final class Store: @unchecked Sendable {
    let lock = NSLock()
    var values: [String: String] = [:]
    func read(_ key: String) -> String? {
      lock.lock()
      defer { lock.unlock() }
      return values[key]
    }
    func write(_ key: String, _ value: String) {
      lock.lock()
      values[key] = value
      lock.unlock()
    }
  }

  func queue(
    _ store: Store, batchSize: Int = 100, maxQueueSize: Int = 1000, flushDelay: TimeInterval = 60
  ) -> EventQueue {
    EventQueue(
      read: { store.read($0) }, write: { store.write($0, $1) },
      logger: LanderLogger(enabled: false), batchSize: batchSize, maxQueueSize: maxQueueSize,
      flushDelay: flushDelay, backoff: Backoff(base: 0.001, max: 0.01, jitter: 0))
  }

  func event(_ id: String) -> EventQueue.Event { ["id": .string(id), "type": "custom", "name": "x"] }

  @Test("persists events and reloads them")
  func persists() async {
    let store = Store()
    let first = queue(store)
    await first.add(event("a"))
    await first.add(event("b"))
    await first.add(event("a"))
    #expect(await first.pending.count == 2, "duplicate IDs are ignored")

    let second = queue(store)
    #expect(await second.pending.map { $0["id"]?.string } == ["a", "b"])
  }

  @Test("sends in batches and empties the queue")
  func batches() async {
    let store = Store()
    let q = queue(store, batchSize: 2)
    let sent = Locked<[[String]]>([])
    await q.setSender { batch in sent.withLock { $0.append(batch.compactMap { $0["id"]?.string }) } }
    for id in ["a", "b", "c"] { await q.add(event(id)) }
    await q.flush()
    #expect(sent.value == [["a", "b"], ["c"]])
    #expect(await q.pending.isEmpty)
    #expect(store.read(EventQueue.storageKey) == "[]")
  }

  @Test("drops the oldest events beyond the maximum size")
  func maxSize() async {
    let q = queue(Store(), maxQueueSize: 2)
    for id in ["a", "b", "c"] { await q.add(event(id)) }
    #expect(await q.pending.map { $0["id"]?.string } == ["b", "c"])
  }

  @Test("validation errors drop the batch; auth errors keep it and pause")
  func errors() async {
    let rejected = queue(Store())
    await rejected.setSender { _ in throw LanderError(code: "validation_error", message: "", statusCode: 400) }
    await rejected.add(event("a"))
    await rejected.flush()
    #expect(await rejected.pending.isEmpty)

    let unauthorized = queue(Store())
    let calls = Locked(0)
    await unauthorized.setSender { _ in
      calls.withLock { $0 += 1 }
      throw LanderError(code: "invalid_api_key", message: "", statusCode: 401)
    }
    await unauthorized.add(event("a"))
    await unauthorized.flush()
    await unauthorized.add(event("b"))
    await unauthorized.flush()
    #expect(await unauthorized.pending.count == 2)
    #expect(calls.value == 1)
  }

  @Test("retryable errors back off and retry on their own")
  func backoff() async {
    let q = queue(Store())
    let calls = Locked(0)
    await q.setSender { _ in
      if calls.withLock({ $0 += 1; return $0 }) < 3 {
        throw LanderError(code: "internal_error", message: "", statusCode: 500)
      }
    }
    await q.add(event("a"))
    await q.flush()
    #expect(await eventually { await q.pending.isEmpty })
    #expect(calls.value == 3)
  }

  @Test("an add schedules a flush after the flush delay")
  func scheduled() async {
    let q = queue(Store(), flushDelay: 0.01)
    let sent = Locked(0)
    await q.setSender { batch in sent.withLock { $0 += batch.count } }
    await q.add(event("a"))
    await q.add(event("b"))
    #expect(await eventually { sent.value == 2 })
  }

  @Test("a corrupt stored queue starts empty")
  func corrupt() async {
    let store = Store()
    store.write(EventQueue.storageKey, "not json")
    #expect(await queue(store).pending.isEmpty)
    store.write(EventQueue.storageKey, #"[{"id": 1}, {"id": "ok"}, 3]"#)
    #expect(await queue(store).pending.map { $0["id"]?.string } == ["ok"])
  }
}

@Suite("Link dispatcher")
struct LinkDispatcherTests {
  func link(_ path: String) -> LanderLink {
    LanderLink(url: URL(string: "https://acme.golander.link\(path)")!, linkId: path, path: path)
  }

  @Test("buffers links until someone listens, then replays them in order")
  func buffers() async {
    let d = LinkDispatcher()
    d.add(link("/a"))
    d.add(link("/b"))
    let got = Collector(d.stream())
    d.add(link("/c"))
    #expect(await eventually { got.items.count == 3 })
    #expect(got.items.map(\.path) == ["/a", "/b", "/c"])
  }

  @Test("every listener gets every link")
  func broadcast() async {
    let d = LinkDispatcher()
    let one = Collector(d.stream())
    let two = Collector(d.stream())
    d.add(link("/a"))
    #expect(await eventually { one.items.count == 1 && two.items.count == 1 })
  }

  @Test("links after the last listener left are buffered for the next one")
  func rebuffers() async {
    let d = LinkDispatcher()
    let first = Collector(d.stream())
    d.add(link("/a"))
    #expect(await eventually { first.items.count == 1 })
    first.cancel()
    #expect(await eventually { !d.hasListeners })
    d.add(link("/b"))
    let second = Collector(d.stream())
    #expect(await eventually { second.items.count == 1 })
    #expect(second.items.map(\.path) == ["/b"])
  }

  @Test("the launch link goes to initialLink when asked first, and never to the stream")
  func initialTaken() async {
    let d = LinkDispatcher()
    async let taken = d.takeInitialLink()
    await pause()
    d.setInitialLink(link("/launch"))
    #expect(await taken?.path == "/launch")
    let got = Collector(d.stream())
    await pause()
    #expect(got.items.isEmpty)
    #expect(await d.takeInitialLink() == nil)
  }

  @Test("a buffered launch link is claimed by initialLink instead of the next listener")
  func initialFromBuffer() async {
    let d = LinkDispatcher()
    d.setInitialLink(link("/launch"))
    #expect(await d.takeInitialLink()?.path == "/launch")
    let got = Collector(d.stream())
    await pause()
    #expect(got.items.isEmpty)
  }

  @Test("once the stream delivered the launch link, initialLink returns nil")
  func initialOnStream() async {
    let d = LinkDispatcher()
    let got = Collector(d.stream())
    d.setInitialLink(link("/launch"))
    #expect(await eventually { got.items.count == 1 })
    #expect(await d.takeInitialLink() == nil)
  }

  @Test("a second initial link goes to the stream")
  func secondInitial() async {
    let d = LinkDispatcher()
    d.setInitialLink(nil)
    d.setInitialLink(link("/late"))
    let got = Collector(d.stream())
    #expect(await eventually { got.items.count == 1 })
    #expect(await d.takeInitialLink() == nil)
  }
}

@Suite("Models")
struct ModelTests {
  @Test("route falls back to the raw URL, with the host of custom schemes as a segment")
  func routes() {
    func route(_ raw: String) -> String { LanderLink.unresolved(URL(string: raw)!).route }
    #expect(route("acmeshop://product/123") == "/product/123")
    #expect(route("acmeshop://Product/123?ref=qr") == "/product/123?ref=qr")
    #expect(route("https://acme.example/products/9?ref=mail") == "/products/9?ref=mail")
    #expect(route("https://acme.example") == "/")
    #expect(route("acmeshop:") == "/")
    #expect(route("https://acme.example/a%20b/") == "/a%20b/")
  }

  @Test("params keep strings, numbers and booleans and drop the rest")
  func params() {
    let link = LanderLink(json: [
      "linkId": "x", "params": ["s": "1", "i": 2, "d": 2.5, "b": false, "n": nil, "o": [:]],
    ])
    #expect(link.params == ["s": "1", "i": 2, "d": 2.5, "b": false])
    #expect(link.params["i"]?.stringValue == "2")
    #expect(link.params["s"]?.intValue == 1)
    #expect(link.params["d"]?.doubleValue == 2.5)
    #expect(link.params["b"]?.boolValue == false)
    #expect(link.url.absoluteString == "about:blank")
  }

  @Test("confidence falls back to unattributed")
  func confidence() {
    #expect(LanderConfidence.parse("deterministic") == .deterministic)
    #expect(LanderConfidence.parse("nope") == .unattributed)
    #expect(LanderConfidence.parse(nil) == .unattributed)
  }

  @Test("short link parsing")
  func shortLink() {
    #expect(LanderShortLink(json: ["id": "x"]) == nil)
    let link = LanderShortLink(json: [
      "id": "x", "url": "https://acme.golander.link/abc", "tags": ["a", 1, "b"],
      "expiresAt": "2027-01-01T00:00:00.000Z",
    ])
    #expect(link?.path == "/")
    #expect(link?.tags == ["a", "b"])
    #expect(link?.expiresAt == Date(timeIntervalSince1970: 1_798_761_600))
  }

  @Test("UUID v5 matches the reference vector")
  func uuidV5() {
    // uuid.v5(Namespace.url, "https://golander.link") from Python's uuid module.
    #expect(
      UUID.v5(namespace: .urlNamespace, name: "https://golander.link").lowercased
        == "d2d73d9d-a468-5d22-adcf-1bc77ef70ebb")
  }
}

@Suite("Facade", .serialized)
struct FacadeTests {
  @Test("accepts publishable keys, trimmed")
  func acceptsKeys() throws {
    #expect(try Lander.validate(apiKey: "  \(testKey)\n") == testKey)
    #expect(throws: Never.self) {
      try Lander.validate(apiKey: "pk_live_ABCDEFGHIJKLMNOPQRSTUVWX")
    }
  }

  @Test("rejects secret keys and malformed keys without echoing them")
  func rejectsKeys() {
    let bad = [
      "sk_live_ABCDEFGHIJKLMNOPQRSTUVWXYZ", "pk_live_ABCDEFGHIJKLMNOPQRSTUVWXsk_",
      "Bearer \(testKey)", "pk_live_short", "pk_prod_ABCDEFGHIJKLMNOPQRSTUVWXYZ",
      "pk_test_ABCDEFGHIJKLMNOPQRSTUV WXYZ", "",
    ]
    for key in bad {
      do {
        _ = try Lander.validate(apiKey: key)
        Issue.record("accepted \(key)")
      } catch let error as LanderError {
        #expect(error.code == "invalid_argument")
        #expect(key.isEmpty || !error.message.contains(key))
        #expect(!error.message.contains("ABCDEFGH"))
      } catch {
        Issue.record("unexpected \(error)")
      }
    }
  }

  @Test("end to end: links handled before initialize and events reach the API")
  func endToEnd() async throws {
    await Lander.resetForTesting()
    let api = FakeTransport(["/v1/sdk/resolve": { _ in json(.object(resolvedP123)) }])
    let platform = FakePlatform()

    #expect(Lander.handle(url: URL(string: "https://acme.golander.link/p-123")!))
    #expect(!Lander.handle(url: URL(fileURLWithPath: "/tmp/x")))
    let activity = NSUserActivity(activityType: "com.acme.other")
    #expect(!Lander.handle(userActivity: activity))
    Lander.trackEvent("signup", properties: ["plan": "pro"])
    Lander.trackEvent("", properties: [:])

    try Lander.initialize(
      apiKey: testKey, baseURL: URL(string: "http://localhost:8787")!, enableLogging: false,
      platform: platform, transport: api
    ) { $0.flushDelay = 0 }
    // A second call is ignored.
    try Lander.initialize(apiKey: testKey)
    platform.send(.launchSettled)

    let link = try #require(await Lander.initialLink())
    #expect(link.path == "/product/123")
    #expect(Lander.installID != nil)
    #expect(await eventually { api.to("/v1/sdk/events").count == 1 })
    let events = api.to("/v1/sdk/events").first?.body["events"]?.array ?? []
    #expect(events.map { $0["name"] } == ["signup"])

    let got = Locked<[String]>([])
    let subscription = Lander.onDeepLink { link in got.withLock { $0.append(link.route) } }
    let activity2 = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
    activity2.webpageURL = URL(string: "https://acme.golander.link/p-123?again=1")
    #expect(Lander.handle(userActivity: activity2))
    #expect(await eventually { got.value == ["/product/123"] })
    subscription.cancel()
    await Lander.resetForTesting()
  }

  @Test("calls that need the SDK fail before initialize")
  func beforeInitialize() async {
    await Lander.resetForTesting()
    #expect(Lander.installID == nil)
    #expect(await Lander.initialLink() == nil)
    do {
      _ = try await Lander.createLink(path: "/x")
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "not_initialized")
    } catch {
      Issue.record("unexpected \(error)")
    }
  }
}

@Suite("File storage")
struct FileStorageTests {
  @Test("stores values in a directory excluded from backups and rejects bad keys")
  func storage() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("lander-tests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let storage = FileStorage(directoryName: "lander", baseDirectory: base)

    #expect(try storage.read("install_id") == nil)
    try storage.write("install_id", "abc")
    #expect(try storage.read("install_id") == "abc")
    try storage.delete("install_id")
    #expect(try storage.read("install_id") == nil)

    let dir = try storage.directory()
    #expect(try dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect(throws: FileStorage.InvalidKey.self) { try storage.write("../escape", "x") }
    #expect(throws: FileStorage.InvalidKey.self) { try storage.read("Upper") }
  }
}
