import Foundation

#if canImport(UIKit)
  import UIKit
#endif

/// Entry point of the Lander SDK.
///
/// ```swift
/// @main
/// struct AcmeApp: App {
///   init() {
///     try? Lander.initialize(apiKey: "pk_live_...")
///   }
///
///   var body: some Scene {
///     WindowGroup {
///       ContentView()
///         .onOpenURL { Lander.handle(url: $0) }
///         .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Lander.handle(userActivity: $0) }
///         .task {
///           for await link in Lander.deepLinks { router.open(link.route) }
///         }
///     }
///   }
/// }
/// ```
public enum Lander {
  /// The SDK version, sent to the API as `sdkVersion`.
  public static let sdkVersion = landerSDKVersion

  /// The default API endpoint.
  public static let defaultBaseURL = URL(string: "https://api.golander.link")!

  /// The format of a publishable key, as in `packages/shared/src/keys.ts`.
  private static let publishableKey = try! NSRegularExpression(
    pattern: "^pk_(test|live)_[A-Za-z0-9]{24,}$")

  // MARK: Setup

  /// Starts the SDK. Call it once, as early as possible: in your `App`'s `init()` or in
  /// `application(_:didFinishLaunchingWithOptions:)`.
  ///
  /// Returns at once. Loading the install ID and reporting the launch with `POST /v1/sdk/init`
  /// happen in the background, so this never waits on the network, and network failures are
  /// logged (when `enableLogging` is on) and never thrown.
  ///
  /// - Parameters:
  ///   - apiKey: A publishable key (`pk_test_...` or `pk_live_...`). Surrounding whitespace is
  ///     ignored. Secret keys are rejected because anything shipped in an app is public.
  ///   - baseURL: The API endpoint. Change it only for local development.
  ///   - enableLogging: Prints diagnostics (links, requests, retries) to the unified log under
  ///     the subsystem `link.golander.lander`. The key is never logged.
  /// - Throws: ``LanderError`` with code `invalid_argument` for a key that is not a publishable
  ///   key. The key itself is never included in the error. A second call is ignored.
  public static func initialize(
    apiKey: String,
    baseURL: URL = Lander.defaultBaseURL,
    enableLogging: Bool = false
  ) throws {
    try initialize(
      apiKey: apiKey, baseURL: baseURL, enableLogging: enableLogging,
      platform: SystemPlatform(), transport: URLSessionTransport())
  }

  static func initialize(
    apiKey: String, baseURL: URL, enableLogging: Bool, platform: any LanderPlatform,
    transport: any LanderTransport, configure: (inout LanderClientConfig) -> Void = { _ in }
  ) throws {
    let key = try validate(apiKey: apiKey)
    var config = LanderClientConfig(apiKey: key, baseURL: baseURL, enableLogging: enableLogging)
    configure(&config)
    let started = state.withLock { state -> Started? in
      if state.client != nil { return nil }
      let client = LanderClient(
        config: config, dispatcher: state.dispatcher, platform: platform, transport: transport)
      state.client = client
      return Started(client: client, links: state.links.stream, events: state.events.stream)
    }
    guard let started else {
      LanderLogger(enabled: enableLogging).log("initialize called twice; ignoring the second call")
      return
    }
    let (client, links, events) = (started.client, started.links, started.events)
    Task {
      await client.start(links: links)
      for await event in events { await client.track(event) }
    }
  }

  /// Checks that `apiKey` is a publishable key and returns it trimmed.
  static func validate(apiKey: String) throws -> String {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.contains("sk_") {
      throw LanderError.invalidArgument(
        "apiKey: secret keys must never ship in an app; use a pk_ key")
    }
    let range = NSRange(key.startIndex..., in: key)
    guard publishableKey.firstMatch(in: key, range: range) != nil else {
      throw LanderError.invalidArgument(
        "apiKey: expected a publishable key such as pk_live_..., with no \"Bearer\" prefix or spaces"
      )
    }
    return key
  }

  // MARK: Receiving links

  /// Hands a URL that opened the app to Lander: a Universal Link or a custom scheme URL.
  ///
  /// Call it from SwiftUI's `.onOpenURL`, `application(_:open:options:)` or
  /// `scene(_:openURLContexts:)`. Safe to call before ``initialize(apiKey:baseURL:enableLogging:)``:
  /// the URL is kept until the SDK starts. The link arrives on ``deepLinks`` (or
  /// ``initialLink()`` for the launch link), resolved by Lander when it is a Lander link.
  ///
  /// - Returns: Whether Lander took the URL. Every web and custom scheme URL is taken (unknown
  ///   links are still delivered, unresolved); `file` URLs are not. If other SDKs (sign in,
  ///   payments) handle URLs too, give them the URL first.
  @discardableResult
  public static func handle(url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty, scheme != "file" else {
      return false
    }
    state.value.links.continuation.yield(
      IncomingLink(raw: url.absoluteString, receivedAt: Date()))
    return true
  }

  /// Hands a Universal Link to Lander, from SwiftUI's
  /// `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`,
  /// `application(_:continue:restorationHandler:)` or `scene(_:continue:)`.
  ///
  /// - Returns: Whether Lander took it: true for a browsing web activity with a URL.
  @discardableResult
  public static func handle(userActivity: NSUserActivity) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else { return false }
    return handle(url: url)
  }

  #if canImport(UIKit) && !os(watchOS)
    /// Hands the URL or Universal Link a scene based app was launched with to Lander. Call it
    /// from `scene(_:willConnectTo:options:)`: on a cold start, UIKit delivers the link there
    /// and not through `scene(_:openURLContexts:)` or `scene(_:continue:)`.
    ///
    /// - Returns: Whether Lander took a link.
    @MainActor
    @discardableResult
    public static func handle(connectionOptions: UIScene.ConnectionOptions) -> Bool {
      var took = false
      for activity in connectionOptions.userActivities where handle(userActivity: activity) {
        took = true
      }
      for context in connectionOptions.urlContexts where handle(url: context.url) {
        took = true
      }
      return took
    }

    /// Hands the URL or Universal Link an app delegate based app was launched with to Lander.
    /// Optional: UIKit also calls `application(_:open:options:)` or
    /// `application(_:continue:restorationHandler:)` after launch, and Lander counts the same
    /// URL reported twice within 2 seconds once.
    ///
    /// - Returns: Whether Lander took a link.
    @MainActor
    @discardableResult
    public static func handle(launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
      guard let launchOptions else { return false }
      var took = false
      if let url = launchOptions[.url] as? URL, handle(url: url) { took = true }
      if let activities = launchOptions[.userActivityDictionary] as? [AnyHashable: Any] {
        for case let activity as NSUserActivity in activities.values
        where handle(userActivity: activity) {
          took = true
        }
      }
      return took
    }
  #endif

  /// Every deep link the app receives: Universal Links, custom scheme URLs and deferred links
  /// (recovered on first launch, with ``LanderLink/isDeferred`` true and their
  /// ``LanderLink/confidence``).
  ///
  /// Each access returns a new stream; iterate it in one task. Safe to use at any time, even
  /// before ``initialize(apiKey:baseURL:enableLogging:)``. Links that arrive while no stream is
  /// listening are buffered and replayed in order to the next one, so nothing is lost while the
  /// app (or its router) starts. When several streams listen, each gets every link. The launch
  /// link is included unless ``initialLink()`` claimed it first.
  ///
  /// Unknown links (not created in Lander) and links that could not be resolved because of the
  /// network are still delivered, with ``LanderLink/isResolved`` false and only
  /// ``LanderLink/url`` set.
  public static var deepLinks: AsyncStream<LanderLink> { state.value.dispatcher.stream() }

  /// Calls `handler` on the main actor for every deep link, as ``deepLinks`` delivers them.
  ///
  /// The subscription lasts until you call ``LanderSubscription/cancel()``; releasing the token
  /// does not end it.
  @discardableResult
  public static func onDeepLink(
    _ handler: @escaping @MainActor @Sendable (LanderLink) -> Void
  ) -> LanderSubscription {
    let stream = deepLinks
    return LanderSubscription(
      task: Task { @MainActor in
        for await link in stream { handler(link) }
      })
  }

  /// The link that launched the app, or nil.
  ///
  /// The launch link is a link handed to ``handle(url:)`` while the app launches (until shortly
  /// after it first becomes active). On a first launch it may instead be a deferred link, so it
  /// waits for the launch report in that case. The launch link is delivered once: if
  /// ``deepLinks`` or an earlier call already delivered it, this returns nil, and once this has
  /// been called ``deepLinks`` will not deliver it.
  ///
  /// Returns nil (and logs a warning) before ``initialize(apiKey:baseURL:enableLogging:)``.
  public static func initialLink() async -> LanderLink? {
    guard let client = state.value.client else {
      LanderLogger.warn("Call Lander.initialize(apiKey:) before Lander.initialLink()")
      return nil
    }
    return await client.initialLink()
  }

  // MARK: Creating links

  /// Creates a short link from inside the app, for share and invite flows.
  ///
  /// The slug is always random and the domain is the project's default domain. Retries wait at
  /// most 10 seconds in total, so a long `Retry-After` comes back as an error with
  /// ``LanderError/retryAfter`` instead.
  ///
  /// - Parameters:
  ///   - path: The in app route the link opens. Must start with `/`.
  ///   - params: Values handed to the app with the link.
  /// - Throws: ``LanderError`` on failure (`invalid_argument` for a path without a leading `/`).
  public static func createLink(
    path: String = "/",
    params: [String: LanderParamValue] = [:],
    title: String? = nil,
    campaign: String? = nil,
    channel: String? = nil,
    tags: [String] = [],
    iosFallbackURL: URL? = nil,
    androidFallbackURL: URL? = nil,
    webFallbackURL: URL? = nil,
    ogTitle: String? = nil,
    ogDescription: String? = nil,
    ogImageURL: URL? = nil,
    expiresAt: Date? = nil
  ) async throws -> LanderShortLink {
    let client = try require("createLink(path:)")
    guard path.hasPrefix("/") else {
      throw LanderError.invalidArgument("createLink: path must start with /")
    }
    var body: [String: JSONValue] = [
      "deepLinkPath": .string(path),
      "params": .object(params.mapValues(\.json)),
    ]
    body["title"] = title.map(JSONValue.string)
    body["campaign"] = campaign.map(JSONValue.string)
    body["channel"] = channel.map(JSONValue.string)
    if !tags.isEmpty { body["tags"] = .array(tags.map(JSONValue.string)) }
    body["iosFallbackUrl"] = iosFallbackURL.map { .string($0.absoluteString) }
    body["androidFallbackUrl"] = androidFallbackURL.map { .string($0.absoluteString) }
    body["webFallbackUrl"] = webFallbackURL.map { .string($0.absoluteString) }
    body["ogTitle"] = ogTitle.map(JSONValue.string)
    body["ogDescription"] = ogDescription.map(JSONValue.string)
    body["ogImageUrl"] = ogImageURL.map { .string($0.absoluteString) }
    body["expiresAt"] = expiresAt.map { .string(ISODate.format($0)) }
    return try await client.createLink(body)
  }

  /// Claims the link your backend handed off to this user, after sign in.
  ///
  /// Your server binds a link to one of its users with `POST /v1/handoffs` (secret key), for
  /// example when someone signs up on your website from a campaign link. After that user signs
  /// in to the app, call this with the same `userId` to get that link (``LanderLink/isDeferred``
  /// true, confidence `deterministic`, method `authenticated_handoff`), or nil when nothing is
  /// pending. The newest pending handoff wins and every pending one for the user is cleared, so
  /// a second call returns nil.
  ///
  /// The link is only returned, never also delivered on ``deepLinks``, so navigate with it
  /// yourself. Use an ID that cannot be guessed (your auth system's user UUID, not an email
  /// address or a counter).
  ///
  /// - Throws: ``LanderError`` when the request fails after retries, or when the install could
  ///   not be registered yet (`install_not_registered`; the registration is retried first).
  public static func claimHandoff(userId: String) async throws -> LanderLink? {
    let client = try require("claimHandoff(userId:)")
    let id = userId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !id.isEmpty, id.count <= 256 else {
      throw LanderError.invalidArgument("claimHandoff: userId must be 1 to 256 characters")
    }
    return try await client.claimHandoff(userId: id)
  }

  // MARK: Events

  /// Records a custom event, for example a signup or a purchase. Fire and forget.
  ///
  /// The event is stored on the device first and sent in batches, with retries, so it survives
  /// offline periods and app restarts. Each event has a client generated ID, so it is counted
  /// once even if it is sent twice. Events tracked before
  /// ``initialize(apiKey:baseURL:enableLogging:)`` are queued until it runs.
  ///
  /// - Parameters:
  ///   - name: 1 to 100 characters.
  ///   - properties: Strings, numbers, booleans, nil, and arrays and dictionaries of those.
  ///   - linkId: ``LanderLink/linkId`` of the link that brought the user in, to attribute the
  ///     event to it.
  ///
  /// An invalid event (empty or too long name, a `linkId` that is not a UUID, properties that
  /// cannot be sent as JSON) is dropped with a warning in the log, never sent: one bad event
  /// would make the API reject its whole batch.
  public static func trackEvent(
    _ name: String, properties: [String: any Sendable] = [:], linkId: String? = nil
  ) {
    do {
      let event = try LanderClient.makeEvent(name: name, properties: properties, linkId: linkId)
      state.value.events.continuation.yield(event)
    } catch {
      LanderLogger.warn("Dropped event \"\(name)\": \((error as? LanderError)?.message ?? "\(error)")")
    }
  }

  /// The random ID Lander created for this install, once the SDK has started. Useful when asking
  /// for support; it is not tied to the device.
  public static var installID: String? { state.value.client?.installID }

  // MARK: Internals

  struct State: Sendable {
    var client: LanderClient?
    var dispatcher = LinkDispatcher()
    var links = AsyncStream.makeStream(of: IncomingLink.self, bufferingPolicy: .unbounded)
    var events = AsyncStream.makeStream(of: EventQueue.Event.self, bufferingPolicy: .unbounded)
  }

  private struct Started: Sendable {
    let client: LanderClient
    let links: AsyncStream<IncomingLink>
    let events: AsyncStream<EventQueue.Event>
  }

  static let state = Locked(State())

  private static func require(_ method: String) throws -> LanderClient {
    guard let client = state.value.client else { throw LanderError.notInitialized(method) }
    return client
  }

  /// Tears the SDK down so tests can initialize it again.
  static func resetForTesting() async {
    let old = state.withLock { state -> LanderClient? in
      let client = state.client
      state = State()
      return client
    }
    await old?.dispose()
  }
}

/// Keeps a ``Lander/onDeepLink(_:)`` handler subscribed until ``cancel()``.
public final class LanderSubscription: Sendable {
  private let task: Task<Void, Never>

  init(task: Task<Void, Never>) { self.task = task }

  /// Stops calling the handler.
  public func cancel() { task.cancel() }
}
