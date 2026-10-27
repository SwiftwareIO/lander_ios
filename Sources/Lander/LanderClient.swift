import Foundation

/// A URL handed to ``Lander/handle(url:)``, with the time it arrived.
struct IncomingLink: Sendable {
  let raw: String
  let receivedAt: Date
}

struct LanderClientConfig: Sendable {
  var apiKey: String
  var baseURL: URL
  var enableLogging = false
  var requestTimeout: TimeInterval = 10
  var flushDelay: TimeInterval = 2
  var eventBackoff = Backoff()
  var requestBackoff = Backoff(base: 0.5, max: 4)

  /// Longest wait for the app to become active before the launch window closes anyway (a
  /// background launch never becomes active).
  var launchWindowCap: TimeInterval = 5
}

/// The SDK engine behind the static ``Lander`` facade. One per app.
actor LanderClient {
  static let installIDKey = "install_id"
  static let firstLaunchReportedKey = "first_launch_reported"

  /// Query parameter of a custom scheme URL carrying the Lander link it stands for.
  static let landerLinkParam = "lander_link"

  /// Repeated identical URLs inside this window count as one open. iOS can report the same
  /// launch URL through more than one callback.
  static let duplicateLinkWindow: TimeInterval = 2

  /// Longest `appVersion` and `osVersion` the API accepts.
  static let maxVersionLength = 50

  nonisolated let dispatcher: LinkDispatcher
  nonisolated let platform: any LanderPlatform
  nonisolated let logger: LanderLogger
  nonisolated let api: LanderAPI
  nonisolated let events: EventQueue
  nonisolated let config: LanderClientConfig

  /// Opens when the first `POST /v1/sdk/init` has finished (or failed).
  nonisolated let initDone = AsyncGate()

  /// Opens when links handled from now on no longer count as the launch link.
  nonisolated let launchWindowClosed = AsyncGate()

  private nonisolated let installIDBox = Locked<String?>(nil)

  private var loaded = false
  private var started = false
  private var isFirstLaunch = false
  private var firstLaunchAtStart = false

  /// Whether the API knows this install (an init succeeded, now or on an earlier launch). Events
  /// wait for it: the API rejects events from unknown installs.
  private var registered = false
  private var registering: Task<Void, Never>?
  private var hasLaunchLink = false
  private var pendingDeferred: LanderLink?
  private var reRegisterTried = false
  private var conflictRetried = false
  private var lastRaw: String?
  private var lastRawAt: Date?
  private var linkChain: Task<Void, Never>?
  private var tasks: [Task<Void, Never>] = []

  init(
    config: LanderClientConfig,
    dispatcher: LinkDispatcher,
    platform: any LanderPlatform,
    transport: any LanderTransport
  ) {
    let logger = LanderLogger(enabled: config.enableLogging)
    self.config = config
    self.dispatcher = dispatcher
    self.platform = platform
    self.logger = logger
    self.api = LanderAPI(
      apiKey: config.apiKey, baseURL: config.baseURL, transport: transport, logger: logger,
      timeout: config.requestTimeout, backoff: config.requestBackoff)
    self.events = EventQueue(
      read: { try platform.read($0) },
      write: { try platform.write($0, $1) },
      logger: logger,
      flushDelay: config.flushDelay,
      backoff: config.eventBackoff)
  }

  /// The random install ID, once loaded.
  nonisolated var installID: String? { installIDBox.value }

  // MARK: Start

  /// Loads local state, starts taking links from `links` and lifecycle events, then reports the
  /// launch in the background. Returns without waiting on the network.
  func start(links: AsyncStream<IncomingLink>) async {
    guard !started else { return }
    started = true
    loadIfNeeded()
    firstLaunchAtStart = isFirstLaunch

    await events.setSender { [weak self] batch in
      guard let self else {
        throw LanderError(code: "disposed", message: "The Lander client was released")
      }
      try await self.sendEvents(batch)
    }

    tasks.append(
      Task { [weak self] in
        for await link in links {
          guard let self else { return }
          await self.receive(link)
        }
      })
    let lifecycle = platform.lifecycleEvents()
    tasks.append(
      Task { [weak self] in
        for await event in lifecycle {
          guard let self else { return }
          await self.handle(event)
        }
      })
    let cap = config.launchWindowCap
    tasks.append(
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: nanoseconds(cap))
        if Task.isCancelled { return }
        await self?.closeLaunchWindow()
      })
    tasks.append(Task { await self.runInit() })
    let events = self.events
    tasks.append(
      Task {
        await events.load()
        await events.flush()
      })
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    var id = safeRead(Self.installIDKey)
    if id == nil || !UUID.isValid(id!) {
      let created = UUID().lowercased
      id = created
      write(Self.installIDKey, created)
      logger.log("Created install ID \(created)")
    }
    installIDBox.set(id)
    isFirstLaunch = safeRead(Self.firstLaunchReportedKey) != "1"
    registered = !isFirstLaunch
  }

  /// Starts over with a new install ID, reported as a first launch.
  private func resetInstall() {
    let created = UUID().lowercased
    installIDBox.set(created)
    write(Self.installIDKey, created)
    do {
      try platform.delete(Self.firstLaunchReportedKey)
    } catch {
      logger.log("Storage delete failed: \(error)")
    }
    isFirstLaunch = true
    registered = false
    logger.log("Created install ID \(created)")
  }

  // MARK: Launch report and deferred link

  private func runInit() async {
    await registerOnce()
    initDone.open()
    if !launchWindowClosed.isOpen { return }
    // The window closed while init was running: settle the launch link now.
    settleInitialLink()
  }

  /// Ends the launch window. Called when the platform reports the launch settled, or after
  /// ``LanderClientConfig/launchWindowCap``.
  func closeLaunchWindow() {
    guard !launchWindowClosed.isOpen else { return }
    launchWindowClosed.open()
    // Only a first launch can produce a deferred link, so do not make initialLink() wait for
    // the network otherwise.
    if !firstLaunchAtStart || initDone.isOpen { settleInitialLink() }
  }

  /// Hands the deferred link (or nil) to the dispatcher as the launch link, unless a link opened
  /// the app: that one wins.
  private func settleInitialLink() {
    let deferred = pendingDeferred
    pendingDeferred = nil
    guard !hasLaunchLink, !dispatcher.initialSettled else { return }
    dispatcher.setInitialLink(deferred)
  }

  /// Registers the install and hands a deferred link from the response to the app. Concurrent
  /// callers share one request. Never throws.
  private func registerOnce() async {
    if let registering {
      await registering.value
      return
    }
    let task = Task {
      await registerAndDeliver()
      registering = nil
    }
    registering = task
    await task.value
  }

  private func registerAndDeliver() async {
    let json = await register()
    // A link that opened the app wins over a deferred one.
    guard let deferred = json?["deferredLink"]?.object, !hasLaunchLink else { return }
    let link = LanderLink(json: deferred)
    logger.log("Deferred link: \(link)")
    if dispatcher.initialSettled {
      // A retried init that succeeded later in the session: deliver on the streams.
      dispatcher.setInitialLink(link)
    } else {
      pendingDeferred = link
      if launchWindowClosed.isOpen && initDone.isOpen { settleInitialLink() }
    }
  }

  /// Retries the registration if no init has succeeded yet, for example after a first launch
  /// offline. Returns whether the install is registered.
  private func ensureRegistered() async -> Bool {
    if !registered { await registerOnce() }
    return registered
  }

  /// `POST /v1/sdk/init`. Returns the response, or nil on failure. Never throws.
  private func register() async -> [String: JSONValue]? {
    let info = platform.platformInfo()
    guard info.platform == "ios" || info.platform == "android" else {
      logger.log("Unsupported platform, skipping init. Links and events still work locally.")
      return nil
    }
    guard let installID else { return nil }
    let firstLaunch = isFirstLaunch
    var body: [String: JSONValue] = [
      "installId": .string(installID),
      "platform": .string(info.platform),
      "appVersion": .string(Self.truncate(info.appVersion)),
      "sdkVersion": .string(landerSDKVersion),
      "isFirstLaunch": .bool(firstLaunch),
    ]
    if let osVersion = info.osVersion { body["osVersion"] = .string(Self.truncate(osVersion)) }

    do {
      let json = try await api.post(
        "/v1/sdk/init", body,
        // A stable key for the install report, so a retry after a lost response (even on the
        // next launch) records one install, not two.
        idempotencyKey: firstLaunch
          ? UUID.v5(namespace: .urlNamespace, name: "lander:install:\(installID)").lowercased
          : UUID().lowercased,
        maxAttempts: firstLaunch ? 3 : 1)
      if firstLaunch {
        // If this marker is lost, the next launch reports a first launch again and gets the same
        // deferred link a second time, so try harder than for other writes before the link is
        // handed to the app.
        if !(await writeWithRetry(Self.firstLaunchReportedKey, "1")) {
          logger.log(
            "Could not save the first launch marker; the next launch may get the deferred link again"
          )
        }
        isFirstLaunch = false
      }
      registered = true
      logger.log("Init ok")
      // Send events that waited for the install to be known.
      let events = self.events
      Task { await events.flush() }
      return json
    } catch let error as LanderError {
      if error.code == "install_id_conflict" && !conflictRetried {
        // The ID belongs to another project or environment, for example after switching from a
        // test key to a live key. Start over with a new one.
        conflictRetried = true
        logger.log("Install ID belongs to another project, creating a new one")
        resetInstall()
        return await register()
      }
      logger.log("Init failed: \(error)")
      return nil
    } catch {
      logger.log("Init failed unexpectedly: \(error)")
      return nil
    }
  }

  static func truncate(_ version: String) -> String {
    version.count > maxVersionLength ? String(version.prefix(maxVersionLength)) : version
  }

  // MARK: Links

  /// Takes a URL from ``Lander/handle(url:)``. Links resolve one after the other, so they reach
  /// the app in arrival order.
  func receive(_ incoming: IncomingLink) {
    let raw = incoming.raw
    let initial = !launchWindowClosed.isOpen && !hasLaunchLink
    if !initial, raw == lastRaw, let last = lastRawAt,
      incoming.receivedAt.timeIntervalSince(last) < Self.duplicateLinkWindow
    {
      logger.log("Ignoring duplicate link \(raw)")
      return
    }
    lastRaw = raw
    lastRawAt = incoming.receivedAt
    if initial {
      hasLaunchLink = true
      pendingDeferred = nil
    }
    let previous = linkChain
    let dispatcher = self.dispatcher
    linkChain = Task {
      await previous?.value
      let link = await resolve(raw)
      if initial {
        dispatcher.setInitialLink(link)
      } else if let link {
        dispatcher.add(link)
      }
    }
  }

  /// Resolves `raw` through the API. Never throws: unknown links and network failures produce
  /// an unresolved link carrying the raw URL.
  private func resolve(_ raw: String) async -> LanderLink? {
    guard let url = URL(string: raw), let components = URLComponents(string: raw) else {
      logger.log("Ignoring unparsable link \(raw)")
      return nil
    }
    var target = raw
    let scheme = url.scheme?.lowercased()
    if scheme != "http" && scheme != "https" {
      // Custom scheme URLs are not Lander short links, unless they carry one in `lander_link`
      // (the "Continue in app" page's open button does).
      let carried = components.queryItems?.first { $0.name == Self.landerLinkParam }?.value
      guard let carried, let carriedURL = URL(string: carried),
        let carriedScheme = carriedURL.scheme?.lowercased(),
        carriedScheme == "https" || carriedScheme == "http"
      else {
        return .unresolved(url)
      }
      target = carriedURL.absoluteString
    }
    // Let init register this install first, but never hold a link for long.
    await initDone.wait(timeout: api.timeout)
    loadIfNeeded()
    do {
      let json = try await api.post(
        "/v1/sdk/resolve",
        ["installId": .string(installID ?? ""), "url": .string(target)],
        idempotencyKey: UUID().lowercased,
        maxAttempts: 2)
      let link = LanderLink(json: json, url: url)
      logger.log("Resolved \(link)")
      return link
    } catch let error as LanderError {
      logger.log(
        error.statusCode == 404 ? "Not a Lander link: \(raw)" : "Resolve failed for \(raw): \(error)")
      return .unresolved(url)
    } catch {
      logger.log("Resolve returned an unexpected response for \(raw): \(error)")
      return .unresolved(url)
    }
  }

  func initialLink() async -> LanderLink? { await dispatcher.takeInitialLink() }

  // MARK: Handoffs and links

  /// `POST /v1/sdk/handoffs/claim`. Returns the link the customer's backend bound to `userId`,
  /// or nil. The link is returned only, never also sent to the streams, so the app navigates
  /// once.
  func claimHandoff(userId: String) async throws -> LanderLink? {
    loadIfNeeded()
    // The API only knows installs that went through init. If it failed, try again now.
    await initDone.wait()
    guard await ensureRegistered() else {
      throw LanderError(
        code: "install_not_registered",
        message: "Lander could not register this install yet (offline?); try again later")
    }
    let json = try await api.post(
      "/v1/sdk/handoffs/claim",
      ["installId": .string(installID ?? ""), "userId": .string(userId)],
      // One key per call, reused across its retries: a retry after a lost response gets the
      // same link instead of nothing.
      idempotencyKey: UUID().lowercased,
      maxAttempts: 3)
    let deferred = json["deferredLink"]
    if deferred == nil || deferred == .null {
      logger.log("No pending handoff")
      return nil
    }
    guard let object = deferred?.object, case let link = LanderLink(json: object), link.isResolved
    else {
      throw LanderError(code: "invalid_response", message: "Unexpected claimHandoff response")
    }
    logger.log("Handoff: \(link)")
    return link
  }

  func createLink(_ body: [String: JSONValue]) async throws -> LanderShortLink {
    loadIfNeeded()
    var body = body
    // installId lets the API rate limit per install instead of per IP.
    if let installID { body["installId"] = .string(installID) }
    let json = try await api.post(
      "/v1/sdk/links", body, idempotencyKey: UUID().lowercased, maxAttempts: 3)
    guard let link = LanderShortLink(json: json) else {
      throw LanderError(code: "invalid_response", message: "Unexpected createLink response")
    }
    return link
  }

  // MARK: Events

  /// Builds a custom event, validating it first: one bad event would make the API reject its
  /// whole batch.
  static func makeEvent(
    name: String, properties: [String: any Sendable], linkId: String?, now: Date = Date()
  ) throws -> EventQueue.Event {
    guard !name.isEmpty, name.count <= 100 else {
      throw LanderError.invalidArgument("trackEvent: name must be 1 to 100 characters")
    }
    if let linkId, !UUID.isValid(linkId) {
      throw LanderError.invalidArgument("trackEvent: linkId must be a Lander link ID (UUID)")
    }
    let props: [String: JSONValue]
    do {
      props = try properties.mapValues { try JSONValue.from(any: $0) }
    } catch let error as JSONValue.UnsupportedValue {
      throw LanderError.invalidArgument(
        "trackEvent: properties must be strings, numbers, booleans, nil, arrays or dictionaries (got \(error.value))"
      )
    }
    var event: EventQueue.Event = [
      "id": .string(UUID().lowercased),
      "type": .string("custom"),
      "name": .string(name),
      "properties": .object(props),
      "occurredAt": .string(ISODate.format(now)),
    ]
    if let linkId { event["linkId"] = .string(linkId) }
    return event
  }

  func track(_ event: EventQueue.Event) async {
    loadIfNeeded()
    await events.add(event)
  }

  private func sendEvents(_ batch: [EventQueue.Event]) async throws {
    loadIfNeeded()
    // An init that failed is retried here, so events do not wait for the next launch.
    guard await ensureRegistered() else {
      // Retried with backoff, and flushed as soon as init succeeds.
      throw LanderError(code: "install_not_registered", message: "Waiting for init to succeed")
    }
    let ids = batch.compactMap { $0["id"]?.string }.sorted()
    do {
      _ = try await api.post(
        "/v1/sdk/events",
        ["installId": .string(installID ?? ""), "events": .array(batch.map(JSONValue.object))],
        idempotencyKey: UUID.v5(
          namespace: .urlNamespace, name: "lander:events:\(ids.joined(separator: ","))"
        ).lowercased)
    } catch let error as LanderError {
      if error.code != "install_not_found" || reRegisterTried { throw error }
      // The API lost this install (for example a reset local database). Register it again
      // once, and keep the events meanwhile.
      reRegisterTried = true
      registered = false
      isFirstLaunch = true
      logger.log("API does not know this install, registering it again")
      Task { await self.registerOnce() }
      throw LanderError(code: error.code, message: error.message)
    }
  }

  // MARK: Lifecycle

  func handle(_ event: LanderLifecycleEvent) {
    switch event {
    case .launchSettled:
      closeLaunchWindow()
    case .didEnterBackground(let finish):
      let events = self.events
      Task {
        await events.flush()
        finish()
      }
    case .willEnterForeground:
      // The init at launch failed (offline?). Back in the foreground is a good moment to try
      // again, without waiting for the next launch.
      if !registered { Task { await self.registerOnce() } }
    }
  }

  // MARK: Storage

  private func safeRead(_ key: String) -> String? {
    do {
      return try platform.read(key)
    } catch {
      logger.log("Storage read failed for \(key): \(error)")
      return nil
    }
  }

  private func write(_ key: String, _ value: String) {
    do {
      try platform.write(key, value)
    } catch {
      logger.log("Storage write failed for \(key): \(error)")
    }
  }

  /// ``write(_:_:)`` with up to `attempts` tries. Never throws.
  private func writeWithRetry(_ key: String, _ value: String, attempts: Int = 3) async -> Bool {
    for attempt in 0..<attempts {
      do {
        try platform.write(key, value)
        return true
      } catch {
        logger.log("Storage write failed for \(key) (try \(attempt + 1) of \(attempts)): \(error)")
        if attempt < attempts - 1 {
          try? await Task.sleep(nanoseconds: UInt64(100_000_000 * (attempt + 1)))
        }
      }
    }
    return false
  }

  /// Stops taking links and lifecycle events and cancels timers. Tests only.
  func dispose() async {
    for task in tasks { task.cancel() }
    tasks = []
    await events.dispose()
  }
}
