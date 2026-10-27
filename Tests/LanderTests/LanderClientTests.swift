import Foundation
import Testing

@testable import Lander

@Suite("Init")
struct InitTests {
  @Test("first launch creates and persists a random install ID and reports isFirstLaunch")
  func firstLaunch() async throws {
    let platform = FakePlatform()
    let api = FakeTransport()
    let client = makeClient(platform, api)
    await started(client)

    let id = try #require(platform.storage[LanderClient.installIDKey])
    #expect(UUID(uuidString: id) != nil)
    #expect(id == id.lowercased())
    #expect(client.installID == id)

    let initReq = try #require(api.to("/v1/sdk/init").first)
    #expect(api.to("/v1/sdk/init").count == 1)
    #expect(
      initReq.body == [
        "installId": .string(id),
        "platform": "ios",
        "appVersion": "2.4.0",
        "sdkVersion": .string(Lander.sdkVersion),
        "osVersion": "18.1",
        "isFirstLaunch": true,
      ])
    #expect(initReq.header("Idempotency-Key") != nil)
    #expect(initReq.header("X-Lander-Sdk") == "ios/0.1.0")
    #expect(initReq.header("Authorization") == "Bearer \(testKey)")
    #expect(platform.storage[LanderClient.firstLaunchReportedKey] == "1")
  }

  @Test("later launches reuse the install ID and report isFirstLaunch false")
  func laterLaunch() async throws {
    let platform = FakePlatform()
    await started(makeClient(platform, FakeTransport()))
    let id = platform.storage[LanderClient.installIDKey]

    let api = FakeTransport()
    await started(makeClient(platform, api))
    let initReq = try #require(api.to("/v1/sdk/init").first)
    #expect(initReq.body["installId"]?.string == id)
    #expect(initReq.body["isFirstLaunch"] == false)
  }

  @Test("a failed first launch report is retried on the next launch with the same key")
  func failedFirstLaunchRetried() async throws {
    let platform = FakePlatform()
    let down = FakeTransport(["/v1/sdk/init": { _ in apiError("internal", 500) }])
    await started(makeClient(platform, down))
    #expect(down.to("/v1/sdk/init").count == 3, "first launch init is retried")
    #expect(platform.storage[LanderClient.firstLaunchReportedKey] == nil)

    let up = FakeTransport()
    await started(makeClient(platform, up))
    let initReq = try #require(up.to("/v1/sdk/init").first)
    #expect(initReq.body["isFirstLaunch"] == true)
    #expect(initReq.header("Idempotency-Key") == down.requests.first?.header("Idempotency-Key"))
  }

  @Test("initialize never waits on or throws for the network")
  func offline() async {
    let api = FakeTransport(["/v1/sdk/init": { _ in throw Offline() }])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    #expect(await client.initialLink() == nil)
  }

  @Test("a 2xx init that is not JSON does not count as the first launch report")
  func captivePortal() async throws {
    let platform = FakePlatform()
    let portal = FakeTransport([
      "/v1/sdk/init": { _ in FakeResponse(status: 200, body: Data("<html>Wi-Fi</html>".utf8)) }
    ])
    await started(makeClient(platform, portal))
    #expect(platform.storage[LanderClient.firstLaunchReportedKey] == nil)

    let up = FakeTransport()
    await started(makeClient(platform, up))
    #expect(up.to("/v1/sdk/init").first?.body["isFirstLaunch"] == true)
    #expect(platform.storage[LanderClient.firstLaunchReportedKey] == "1")
  }

  @Test("appVersion and osVersion are cut to the 50 characters the API accepts")
  func truncatesVersions() async throws {
    let long = "1.0.0+" + String(repeating: "b", count: 60)
    let api = FakeTransport()
    await started(
      makeClient(
        FakePlatform(appVersion: long, osVersion: String(repeating: "x", count: 80)), api))
    let body = try #require(api.to("/v1/sdk/init").first?.body)
    #expect(body["appVersion"]?.string == String(long.prefix(50)))
    #expect(body["osVersion"]?.string == String(repeating: "x", count: 50))
  }

  @Test("an unsupported platform skips init")
  func unsupportedPlatform() async {
    let api = FakeTransport()
    let client = makeClient(FakePlatform(platform: "macos"), api)
    await started(client)
    #expect(api.to("/v1/sdk/init").isEmpty)
    #expect(await client.initialLink() == nil)
  }
}

@Suite("Deferred links")
struct DeferredLinkTests {
  func deferredAPI(_ link: [String: JSONValue] = deferredSpring) -> FakeTransport {
    FakeTransport([
      "/v1/sdk/init": { r in
        json([
          "installId": r.body["installId"] ?? .null,
          "deferredLink": r.body["isFirstLaunch"] == true ? .object(link) : .null,
        ])
      }
    ])
  }

  @Test("a deferred link from init becomes the initial link")
  func deferredIsInitial() async throws {
    let client = makeClient(FakePlatform(), deferredAPI())
    await started(client)
    let link = try #require(await client.initialLink())
    #expect(link.isDeferred)
    #expect(link.path == "/sale/spring")
    #expect(link.route == "/sale/spring")
    #expect(link.confidence == .probabilistic)
    #expect(link.method == "probabilistic_match")
    #expect(link.params == ["discount": "15"])
    #expect(link.url.absoluteString == "https://acme.golander.link/spring-sale")
    #expect(link.shortURL?.absoluteString == "https://acme.golander.link/spring-sale")
    #expect(await client.initialLink() == nil, "delivered once")
  }

  @Test("is delivered exactly once, through the stream when nobody asks initialLink")
  func deliveredOnceOnStream() async {
    let platform = FakePlatform()
    let dispatcher = LinkDispatcher()
    let got = Collector(dispatcher.stream())
    let client = makeClient(platform, deferredAPI(), dispatcher: dispatcher)
    await started(client)
    #expect(await eventually { got.items.count == 1 })
    #expect(got.items.first?.isDeferred == true)
    #expect(await client.initialLink() == nil, "the stream already delivered it")

    // The next launch is not a first launch: nothing is recovered again.
    let api2 = deferredAPI()
    let dispatcher2 = LinkDispatcher()
    let again = Collector(dispatcher2.stream())
    let client2 = makeClient(platform, api2, dispatcher: dispatcher2)
    await started(client2)
    #expect(api2.to("/v1/sdk/init").first?.body["isFirstLaunch"] == false)
    #expect(again.items.isEmpty)
    #expect(await client2.initialLink() == nil)
  }

  @Test("waits for the launch window: init answering first still delivers the deferred link")
  func initBeforeWindowCloses() async throws {
    let client = makeClient(FakePlatform(), deferredAPI())
    await client.start(links: AsyncStream { _ in })
    await client.initDone.wait()
    await client.closeLaunchWindow()
    let link = try #require(await client.initialLink())
    #expect(link.linkId == deferredSpring["linkId"]?.string)
  }

  @Test("a link that opened the app wins over a deferred link")
  func launchLinkWins() async {
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        json(["installId": r.body["installId"] ?? .null, "deferredLink": .object(deferredSpring)])
      },
      "/v1/sdk/resolve": { _ in json(.object(resolvedP123)) },
    ])
    let dispatcher = LinkDispatcher()
    let got = Collector(dispatcher.stream())
    let client = makeClient(FakePlatform(), api, dispatcher: dispatcher)
    await started(client, launchLinks: ["https://acme.golander.link/p-123"])
    #expect(await eventually { got.items.count == 1 })
    await pause()
    #expect(got.items.map(\.path) == ["/product/123"])
  }

  @Test("a link handed over during launch before init also wins")
  func launchLinkDuringWindow() async throws {
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        json(["installId": r.body["installId"] ?? .null, "deferredLink": .object(deferredSpring)])
      },
      "/v1/sdk/resolve": { _ in json(.object(resolvedP123)) },
    ])
    let client = makeClient(FakePlatform(), api)
    let (links, input) = AsyncStream.makeStream(of: IncomingLink.self)
    await client.start(links: links)
    input.yield(IncomingLink(raw: "https://acme.golander.link/p-123", receivedAt: Date()))
    await pause()
    await client.closeLaunchWindow()
    let link = try #require(await client.initialLink())
    #expect(link.path == "/product/123")
    #expect(!link.isDeferred)
  }

  @Test("no deferred link: initialLink is nil after init")
  func noDeferred() async {
    let client = makeClient(FakePlatform(), FakeTransport())
    await started(client)
    #expect(await client.initialLink() == nil)
  }

  @Test("a malformed deferred link is still delivered")
  func malformedDeferred() async throws {
    let api = deferredAPI(deferredSpring.with(["url": 42, "params": "discount=15", "campaign": 7]))
    let client = makeClient(FakePlatform(), api)
    await started(client)
    let link = try #require(await client.initialLink())
    #expect(link.linkId == deferredSpring["linkId"]?.string)
    #expect(link.route == "/sale/spring")
    #expect(link.isDeferred)
    #expect(link.params.isEmpty)
    #expect(link.campaign == nil)
  }

  @Test("a failed first launch marker write is retried before the deferred link is delivered")
  func markerWriteRetried() async throws {
    let platform = FakePlatform()
    platform.failWrites(LanderClient.firstLaunchReportedKey, count: 2)
    let client = makeClient(platform, deferredAPI())
    await started(client)
    #expect(await client.initialLink()?.linkId == deferredSpring["linkId"]?.string)
    #expect(platform.storage[LanderClient.firstLaunchReportedKey] == "1")

    let api2 = FakeTransport()
    await started(makeClient(platform, api2))
    #expect(api2.to("/v1/sdk/init").first?.body["isFirstLaunch"] == false)
  }

  @Test("a custom scheme URL carrying lander_link resolves that link")
  func carriedLink() async throws {
    let carried = "https://acme.golander.link/spring-sale?lander_token=AbCdEfGh12345678"
    let encoded = carried.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
    let raw = "acmeshop://sale/spring?lander_link=\(encoded)"
    let api = FakeTransport([
      "/v1/sdk/resolve": { _ in json(.object(deferredSpring.with(["method": "landing_page"]))) }
    ])
    let client = makeClient(FakePlatform(), api)
    await started(client, launchLinks: [raw])
    let link = try #require(await client.initialLink())
    #expect(api.to("/v1/sdk/resolve").first?.body["url"]?.string == carried)
    #expect(link.isResolved)
    #expect(link.method == "landing_page")
    #expect(link.isDeferred)
    #expect(link.route == "/sale/spring")
    #expect(link.url.absoluteString == raw, "url stays what iOS delivered")
  }

  @Test("when that resolve fails, the scheme URL still routes to the right screen")
  func carriedLinkOffline() async throws {
    let raw = "acmeshop://sale/spring?lander_link=https%3A%2F%2Facme.golander.link%2Fx"
    let api = FakeTransport(["/v1/sdk/resolve": { _ in throw Offline() }])
    let client = makeClient(FakePlatform(), api)
    await started(client, launchLinks: [raw])
    let link = try #require(await client.initialLink())
    #expect(!link.isResolved)
    #expect(link.route.hasPrefix("/sale/spring?"))
  }
}

@Suite("Registration")
struct RegistrationTests {
  @Test("install_id_conflict creates a new install ID and reports a first launch")
  func conflictReset() async throws {
    let oldID = "11111111-2222-4333-8444-555555555555"
    let platform = FakePlatform(storage: [
      LanderClient.installIDKey: oldID, LanderClient.firstLaunchReportedKey: "1",
    ])
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        r.body["installId"]?.string == oldID
          ? apiError("install_id_conflict", 409)
          : json(["installId": r.body["installId"] ?? .null, "deferredLink": .null])
      }
    ])
    let client = makeClient(platform, api)
    await started(client)

    let inits = api.to("/v1/sdk/init")
    #expect(inits.count == 2)
    #expect(inits.last?.body["isFirstLaunch"] == true)
    #expect(client.installID != oldID)
    #expect(platform.storage[LanderClient.installIDKey] == client.installID)
    #expect(platform.storage[LanderClient.firstLaunchReportedKey] == "1")
  }

  @Test("a failed first launch init is retried in the foreground, once at a time")
  func retriedInForeground() async throws {
    let up = Locked(false)
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        guard up.value else { throw Offline() }
        return json(["installId": r.body["installId"] ?? .null, "deferredLink": .object(deferredSpring)])
      }
    ])
    let platform = FakePlatform()
    let dispatcher = LinkDispatcher()
    let got = Collector(dispatcher.stream())
    let client = makeClient(platform, api, dispatcher: dispatcher)
    await started(client)
    #expect(await client.initialLink() == nil)
    let failed = api.to("/v1/sdk/init").count

    up.set(true)
    await client.handle(.willEnterForeground)
    await client.handle(.willEnterForeground)
    #expect(await eventually { got.items.count == 1 })
    await pause()

    #expect(api.to("/v1/sdk/init").count == failed + 1, "concurrent retries share one request")
    #expect(api.to("/v1/sdk/init").last?.body["isFirstLaunch"] == true)
    #expect(platform.storage[LanderClient.firstLaunchReportedKey] == "1")
    #expect(got.items.map(\.linkId) == [deferredSpring["linkId"]?.string], "late deferred link goes to the stream")

    await client.handle(.willEnterForeground)
    await pause()
    #expect(api.to("/v1/sdk/init").count == failed + 1, "no retry once registered")
  }

  @Test("events wait for a successful init instead of being dropped")
  func eventsWaitForInit() async throws {
    let initUp = Locked(false)
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        initUp.value
          ? json(["installId": r.body["installId"] ?? .null, "deferredLink": .null])
          : apiError("internal_error", 500)
      }
    ])
    let platform = FakePlatform()
    let first = makeClient(platform, api)
    await started(first)
    await first.track(try LanderClient.makeEvent(name: "purchase", properties: [:], linkId: nil))
    await pause()
    #expect(api.to("/v1/sdk/events").isEmpty, "install not registered yet")
    #expect(await first.events.pending.count == 1)
    await first.dispose()
    // Let a flush that was already running when the client was disposed finish.
    await pause(0.2)

    initUp.set(true)
    let second = makeClient(platform, api)
    await started(second)
    #expect(await eventually { api.to("/v1/sdk/events").count == 1 })
    #expect(await eventually { await second.events.pending.isEmpty })
  }

  @Test("install_not_found on events registers the install again and keeps the events")
  func installNotFound() async throws {
    let known = Locked(false)
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        known.set(r.body["isFirstLaunch"] == true)
        return json(["installId": r.body["installId"] ?? .null, "deferredLink": .null])
      },
      "/v1/sdk/events": { _ in
        known.value ? json(["accepted": 1, "duplicates": 0], 202) : apiError("install_not_found", 404)
      },
    ])
    // Looks registered locally, but the API forgot it (database reset).
    let platform = FakePlatform(storage: [LanderClient.firstLaunchReportedKey: "1"])
    let client = makeClient(platform, api)
    await started(client)
    await client.track(try LanderClient.makeEvent(name: "purchase", properties: [:], linkId: nil))

    #expect(await eventually { await client.events.pending.isEmpty })
    #expect(api.to("/v1/sdk/init").last?.body["isFirstLaunch"] == true)
    #expect(api.to("/v1/sdk/events").count >= 2)
  }
}

@Suite("Resolve")
struct ResolveTests {
  @Test("a known link resolves to a LanderLink with its params")
  func resolves() async throws {
    let api = FakeTransport(["/v1/sdk/resolve": { _ in json(.object(resolvedP123)) }])
    let client = makeClient(FakePlatform(), api)
    await started(client, launchLinks: ["https://acme.golander.link/p-123?utm_source=x"])

    let link = try #require(await client.initialLink())
    #expect(link.isResolved)
    #expect(link.linkId == resolvedP123["linkId"]?.string)
    #expect(link.path == "/product/123")
    #expect(link.route == "/product/123")
    #expect(link.params == ["productId": "123", "utm_source": "x"])
    #expect(link.channel == "share")
    #expect(link.campaign == nil)
    #expect(!link.isDeferred)
    #expect(link.confidence == .deterministic)
    #expect(link.url.absoluteString == "https://acme.golander.link/p-123?utm_source=x")

    let resolve = try #require(api.to("/v1/sdk/resolve").first)
    #expect(
      resolve.body == [
        "installId": .string(client.installID!),
        "url": "https://acme.golander.link/p-123?utm_source=x",
      ])
    #expect(resolve.header("Idempotency-Key") != nil)
    #expect(api.requests.first?.path == "/v1/sdk/init", "init registers the install before resolve")
  }

  @Test("an unknown link (404) is still delivered with the raw URL")
  func unknownLink() async throws {
    let api = FakeTransport()
    let client = makeClient(FakePlatform(), api)
    await started(client, launchLinks: ["https://acme.example/products/9?ref=mail"])
    let link = try #require(await client.initialLink())
    #expect(!link.isResolved)
    #expect(link.url.absoluteString == "https://acme.example/products/9?ref=mail")
    #expect(link.route == "/products/9?ref=mail")
    #expect(link.params.isEmpty)
    #expect(api.to("/v1/sdk/resolve").count == 1, "404 is not retried")
  }

  @Test("a network failure delivers the raw URL instead of losing the link")
  func networkFailure() async throws {
    let api = FakeTransport(["/v1/sdk/resolve": { _ in throw Offline() }])
    let client = makeClient(FakePlatform(), api)
    await started(client, launchLinks: ["https://acme.golander.link/p-123"])
    let link = try #require(await client.initialLink())
    #expect(!link.isResolved)
    #expect(link.route == "/p-123")
    #expect(api.to("/v1/sdk/resolve").count == 2, "resolve is tried twice")
  }

  @Test("custom scheme URLs are delivered without a network call")
  func customScheme() async throws {
    let api = FakeTransport()
    let client = makeClient(FakePlatform(), api)
    await started(client, launchLinks: ["acmeshop://product/123?ref=qr"])
    let link = try #require(await client.initialLink())
    #expect(link.route == "/product/123?ref=qr")
    #expect(api.to("/v1/sdk/resolve").isEmpty)
  }

  @Test("warm start links are resolved and delivered in arrival order")
  func arrivalOrder() async {
    let api = FakeTransport([
      "/v1/sdk/resolve": { r in
        let url = r.body["url"]?.string ?? ""
        // The first link resolves slowly; order must still hold.
        if url.hasSuffix("slow") { await pause(0.05) }
        return json(.object(resolvedP123.with(["path": .string(URL(string: url)!.path)])))
      }
    ])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    let got = Collector(client.dispatcher.stream())
    await client.receive(IncomingLink(raw: "https://acme.golander.link/slow", receivedAt: Date()))
    await client.receive(IncomingLink(raw: "https://acme.golander.link/fast", receivedAt: Date()))
    #expect(await eventually { got.items.count == 2 })
    #expect(got.items.map(\.path) == ["/slow", "/fast"])
  }

  @Test("the same URL reported twice in a row counts once")
  func duplicate() async {
    let api = FakeTransport()
    let client = makeClient(FakePlatform(), api)
    let got = Collector(client.dispatcher.stream())
    await started(client, launchLinks: ["https://acme.golander.link/p-123"])
    await client.receive(IncomingLink(raw: "https://acme.golander.link/p-123", receivedAt: Date()))
    await pause()
    #expect(got.items.count == 1, "the launch link, delivered once")
    #expect(api.to("/v1/sdk/resolve").count == 1)
  }

  @Test("the same URL after the duplicate window counts again")
  func duplicateWindow() async {
    let client = makeClient(FakePlatform(), FakeTransport())
    await started(client)
    let got = Collector(client.dispatcher.stream())
    let now = Date()
    await client.receive(IncomingLink(raw: "acmeshop://a", receivedAt: now))
    await client.receive(IncomingLink(raw: "acmeshop://a", receivedAt: now.addingTimeInterval(1)))
    await client.receive(IncomingLink(raw: "acmeshop://a", receivedAt: now.addingTimeInterval(3.5)))
    #expect(await eventually { got.items.count == 2 })
    await pause()
    #expect(got.items.count == 2)
  }

  @Test("links that arrive before anyone listens are replayed to the first listener")
  func buffered() async {
    let client = makeClient(FakePlatform(), FakeTransport())
    await started(client)
    await client.receive(IncomingLink(raw: "acmeshop://one", receivedAt: Date()))
    await client.receive(IncomingLink(raw: "acmeshop://two", receivedAt: Date()))
    await pause()
    let got = Collector(client.dispatcher.stream())
    #expect(await eventually { got.items.count == 2 })
    #expect(got.items.map(\.route) == ["/one", "/two"])
  }
}

@Suite("claimHandoff")
struct ClaimHandoffTests {
  let handoff = deferredSpring.with([
    "params": ["discount": "15", "ref": "email"], "confidence": "deterministic",
    "method": "authenticated_handoff",
  ])

  @Test("returns the handed off link without emitting it on the stream")
  func claims() async throws {
    let handoff = self.handoff
    let api = FakeTransport([
      "/v1/sdk/handoffs/claim": { _ in json(["deferredLink": .object(handoff)]) }
    ])
    let client = makeClient(FakePlatform(), api)
    let got = Collector(client.dispatcher.stream())
    await started(client)

    let link = try #require(try await client.claimHandoff(userId: "user_8f2c"))
    #expect(link.isDeferred)
    #expect(link.confidence == .deterministic)
    #expect(link.method == "authenticated_handoff")
    #expect(link.params == ["discount": "15", "ref": "email"])
    await pause()
    #expect(got.items.isEmpty)
    let req = try #require(api.to("/v1/sdk/handoffs/claim").first)
    #expect(req.body == ["installId": .string(client.installID!), "userId": "user_8f2c"])
    #expect(req.header("Idempotency-Key") != nil)
  }

  @Test("returns nil when nothing is pending")
  func nothingPending() async throws {
    let api = FakeTransport(["/v1/sdk/handoffs/claim": { _ in json(["deferredLink": nil]) }])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    #expect(try await client.claimHandoff(userId: "user_8f2c") == nil)
  }

  @Test("retries with one Idempotency-Key, then throws")
  func retries() async throws {
    let handoff = self.handoff
    let calls = Locked(0)
    let api = FakeTransport([
      "/v1/sdk/handoffs/claim": { _ in
        calls.withLock { $0 += 1; return $0 } < 2
          ? apiError("internal_error", 500) : json(["deferredLink": .object(handoff)])
      }
    ])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    #expect(try await client.claimHandoff(userId: "u")?.linkId == deferredSpring["linkId"]?.string)
    #expect(Set(api.to("/v1/sdk/handoffs/claim").map { $0.header("Idempotency-Key") }).count == 1)

    let down = FakeTransport(["/v1/sdk/handoffs/claim": { _ in apiError("internal_error", 500) }])
    let client2 = makeClient(FakePlatform(), down)
    await started(client2)
    await #expect(throws: LanderError.self) { try await client2.claimHandoff(userId: "u") }
    #expect(down.to("/v1/sdk/handoffs/claim").count == 3)
  }

  @Test("a malformed handoff response throws invalid_response")
  func malformed() async throws {
    let bodies: [JSONValue] = [["linkId": 7], "https://acme.golander.link/spring-sale", [:]]
    for body in bodies {
      let api = FakeTransport(["/v1/sdk/handoffs/claim": { _ in json(["deferredLink": body]) }])
      let client = makeClient(FakePlatform(), api)
      await started(client)
      do {
        _ = try await client.claimHandoff(userId: "u")
        Issue.record("expected an error for \(body)")
      } catch let error as LanderError {
        #expect(error.code == "invalid_response")
      }
    }
  }

  @Test("throws install_not_registered when init never succeeded")
  func notRegistered() async throws {
    let api = FakeTransport(["/v1/sdk/init": { _ in throw Offline() }])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    do {
      _ = try await client.claimHandoff(userId: "u")
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "install_not_registered")
    }
    #expect(api.to("/v1/sdk/handoffs/claim").isEmpty)
  }

  @Test("retries a failed init before claiming")
  func retriesInit() async throws {
    let up = Locked(false)
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        guard up.value else { throw Offline() }
        return json(["installId": r.body["installId"] ?? .null, "deferredLink": .null])
      },
      "/v1/sdk/handoffs/claim": { _ in json(["deferredLink": nil]) },
    ])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    let failed = api.to("/v1/sdk/init").count
    up.set(true)
    #expect(try await client.claimHandoff(userId: "user_8f2c") == nil)
    #expect(api.to("/v1/sdk/init").count == failed + 1)
    #expect(api.to("/v1/sdk/handoffs/claim").count == 1)
  }
}

@Suite("Events")
struct EventTests {
  @Test("trackEvent queues, persists and sends a batch with client IDs")
  func sendsBatch() async throws {
    let platform = FakePlatform()
    let api = FakeTransport()
    let client = makeClient(platform, api, flushDelay: 60)
    await started(client)

    let linkId = resolvedP123["linkId"]!.string!
    await client.track(
      try LanderClient.makeEvent(
        name: "purchase", properties: ["amount": 49.99, "currency": "USD"], linkId: linkId))
    await client.track(try LanderClient.makeEvent(name: "signup", properties: [:], linkId: nil))
    #expect(platform.storage[EventQueue.storageKey]?.contains("purchase") == true, "persisted first")
    await client.events.flush()

    let batches = api.to("/v1/sdk/events")
    #expect(batches.count == 1)
    let sent = try #require(batches.first?.body["events"]?.array).compactMap(\.object)
    #expect(sent.map { $0["name"]?.string } == ["purchase", "signup"])
    let event = try #require(sent.first)
    #expect(event["type"] == "custom")
    #expect(event["properties"] == ["amount": 49.99, "currency": "USD"])
    #expect(event["linkId"]?.string == linkId)
    #expect(sent.last?["linkId"] == nil)
    #expect(UUID(uuidString: event["id"]?.string ?? "") != nil)
    let occurredAt = try #require(event["occurredAt"]?.string)
    #expect(occurredAt.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$"#, options: .regularExpression) != nil)
    #expect(batches.first?.body["installId"]?.string == client.installID)
    #expect(batches.first?.header("Idempotency-Key") != nil)
    #expect(platform.storage[EventQueue.storageKey] == "[]")
  }

  @Test("events tracked offline are sent on the next launch")
  func offlineThenNextLaunch() async throws {
    let platform = FakePlatform()
    let offline = FakeTransport(["/v1/sdk/events": { _ in throw Offline() }])
    let first = makeClient(platform, offline, flushDelay: 60)
    await started(first)
    await first.track(try LanderClient.makeEvent(name: "purchase", properties: ["amount": 1], linkId: nil))
    await first.events.flush()
    await first.dispose()
    let pending = await first.events.pending
    #expect(pending.count == 1)
    let id = pending.first?["id"]

    let online = FakeTransport()
    let second = makeClient(platform, online)
    await started(second)
    #expect(await eventually { !online.to("/v1/sdk/events").isEmpty })
    let sent = online.to("/v1/sdk/events").flatMap { $0.body["events"]?.array ?? [] }
    #expect(sent.map { $0["id"] } == [id])
  }

  @Test("retries a failed batch with the same idempotency key")
  func retriesBatch() async throws {
    let calls = Locked(0)
    let api = FakeTransport([
      "/v1/sdk/events": { _ in
        calls.withLock { $0 += 1; return $0 } == 1
          ? apiError("internal", 503) : json(["accepted": 1, "duplicates": 0], 202)
      }
    ])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    await client.track(try LanderClient.makeEvent(name: "purchase", properties: [:], linkId: nil))
    #expect(await eventually { api.to("/v1/sdk/events").count == 2 })
    let sends = api.to("/v1/sdk/events")
    #expect(sends[0].header("Idempotency-Key") == sends[1].header("Idempotency-Key"))
    #expect(sends[0].body["events"] == sends[1].body["events"])
    #expect(await eventually { await client.events.pending.isEmpty })
  }

  @Test("rejects invalid names, link IDs and properties")
  func validation() {
    #expect(throws: LanderError.self) {
      try LanderClient.makeEvent(name: "", properties: [:], linkId: nil)
    }
    #expect(throws: LanderError.self) {
      try LanderClient.makeEvent(name: String(repeating: "x", count: 101), properties: [:], linkId: nil)
    }
    #expect(throws: LanderError.self) {
      try LanderClient.makeEvent(name: "ok", properties: ["when": Date()], linkId: nil)
    }
    #expect(throws: LanderError.self) {
      try LanderClient.makeEvent(name: "ok", properties: [:], linkId: "p-123")
    }
  }

  @Test("properties keep their JSON types")
  func propertyTypes() throws {
    let optional: String? = nil
    let event = try LanderClient.makeEvent(
      name: "ok",
      properties: [
        "s": "x", "i": 3, "d": 1.5, "b": true, "n": optional, "nested": ["a": [1, 2]],
        "ns": NSNumber(value: false),
      ],
      linkId: nil)
    #expect(
      event["properties"] == [
        "s": "x", "i": 3, "d": 1.5, "b": true, "n": nil, "nested": ["a": [1, 2]], "ns": false,
      ])
  }

  @Test("flushes events when the app goes to the background")
  func backgroundFlush() async throws {
    let api = FakeTransport()
    let platform = FakePlatform()
    let client = makeClient(platform, api, flushDelay: 3600)
    await client.start(links: AsyncStream { _ in })
    await client.closeLaunchWindow()
    await client.initDone.wait()
    await client.track(try LanderClient.makeEvent(name: "purchase", properties: [:], linkId: nil))
    await pause()
    #expect(api.to("/v1/sdk/events").isEmpty)

    let finished = Locked(false)
    platform.send(.didEnterBackground(finish: { finished.set(true) }))
    #expect(await eventually { api.to("/v1/sdk/events").count == 1 })
    #expect(await eventually { finished.value })
  }

  @Test("queued events retry a failed init in the same session")
  func retryInitForEvents() async throws {
    let up = Locked(false)
    let api = FakeTransport([
      "/v1/sdk/init": { r in
        guard up.value else { throw Offline() }
        return json(["installId": r.body["installId"] ?? .null, "deferredLink": .null])
      }
    ])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    await client.track(try LanderClient.makeEvent(name: "purchase", properties: [:], linkId: nil))
    await pause()
    #expect(api.to("/v1/sdk/events").isEmpty)

    up.set(true)
    #expect(await eventually { api.to("/v1/sdk/events").count == 1 })
    #expect(await eventually { await client.events.pending.isEmpty })
  }
}

@Suite("createLink")
struct CreateLinkTests {
  @Test("posts to /v1/sdk/links and parses the link")
  func creates() async throws {
    let api = FakeTransport([
      "/v1/sdk/links": { r in
        json(
          [
            "id": "0d6f1a7e-1111-4222-8333-944445555666",
            "url": "https://acme.golander.link/x7Kp2Qa",
            "domain": "acme.golander.link",
            "slug": "x7Kp2Qa",
            "title": nil,
            "deepLinkPath": r.body["deepLinkPath"] ?? nil,
            "params": r.body["params"] ?? nil,
            "campaign": nil,
            "channel": "share",
            "tags": [],
            "expiresAt": nil,
            "enabled": true,
            "createdAt": "2026-10-15T10:00:00Z",
            "updatedAt": "2026-10-15T10:00:00Z",
          ], 201)
      }
    ])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    let link = try await client.createLink([
      "deepLinkPath": "/product/123", "params": ["productId": "123"], "channel": "share",
    ])
    #expect(link.url.absoluteString == "https://acme.golander.link/x7Kp2Qa")
    #expect(link.path == "/product/123")
    #expect(link.params == ["productId": "123"])
    #expect(link.channel == "share")
    #expect(link.createdAt == Date(timeIntervalSince1970: 1_792_058_400))
    let req = try #require(api.to("/v1/sdk/links").first)
    #expect(req.header("Idempotency-Key") != nil)
    #expect(req.body["installId"]?.string == client.installID)
  }

  @Test("throws LanderError on failure after retrying with one key")
  func fails() async throws {
    let api = FakeTransport(["/v1/sdk/links": { _ in apiError("internal", 500) }])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    await #expect(throws: LanderError.self) { try await client.createLink(["deepLinkPath": "/"]) }
    let reqs = api.to("/v1/sdk/links")
    #expect(reqs.count == 3)
    #expect(Set(reqs.map { $0.header("Idempotency-Key") }).count == 1)
  }

  @Test("a response it cannot use is invalid_response")
  func invalidResponse() async throws {
    let api = FakeTransport(["/v1/sdk/links": { _ in json(["id": 1], 201) }])
    let client = makeClient(FakePlatform(), api)
    await started(client)
    do {
      _ = try await client.createLink(["deepLinkPath": "/"])
      Issue.record("expected an error")
    } catch let error as LanderError {
      #expect(error.code == "invalid_response")
    }
  }
}
