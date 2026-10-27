# Lander for iOS

Deep linking without the fuss. The native iOS SDK for [Lander](https://golander.link): receive Universal Links and custom scheme URLs, resolve them to the link you created in Lander, create short links from inside the app, and report conversions.

- One stream for every link: cold start, warm start, deferred (after install).
- Every link says how sure Lander is: `deterministic`, `probabilistic` or `unattributed`.
- Links are buffered until your router listens, so nothing is lost during startup.
- Unknown links still reach your app with the raw URL.
- Offline event queue with batching, retries and deduplication.
- Privacy first: a random install ID, no fingerprinting, no IDFA, no pasteboard reads.

Requires iOS 15+ and Xcode 16+ (Swift 6). Works with Swift 5 and Swift 6 language mode apps, SwiftUI and UIKit. Full docs: [golander.link/docs/ios](https://golander.link/docs/ios).

## Install

### Swift Package Manager

In Xcode: File, Add Package Dependencies, then enter `https://github.com/SwiftwareIO/lander_ios` and add the `Lander` library to your app target. Or in `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/SwiftwareIO/lander_ios", from: "0.1.0")
],
targets: [
  .target(name: "AcmeShop", dependencies: [.product(name: "Lander", package: "lander_ios")])
]
```

### CocoaPods

```ruby
pod 'LanderSDK', '~> 0.1'
```

The pod is named `LanderSDK`; the module is still `Lander`, so you write `import Lander` either way.

## Set up your app

1. **Associated Domains.** In Xcode, select your app target, Signing & Capabilities, add Associated Domains and add your link domain:

   ```text
   applinks:acme.golander.link
   ```

   This writes `com.apple.developer.associated-domains` into your `.entitlements` file. Add custom domains the same way.

2. **Register the app in Lander.** In the dashboard, open the project's Apps page and add your Apple Team ID and bundle ID. Lander then serves `/.well-known/apple-app-site-association` for every domain of the project; nothing to host yourself.

3. **Custom URL scheme (recommended).** Add one in `Info.plist` (or the target's Info tab, URL Types). The "Continue in app" page opens your app through it after an install, carrying the Lander link in a `lander_link` query parameter that the SDK resolves for you.

   ```xml
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleURLName</key>
       <string>com.acme.shop</string>
       <key>CFBundleURLSchemes</key>
       <array><string>acmeshop</string></array>
     </dict>
   </array>
   ```

## Usage

### SwiftUI

```swift
import Lander
import SwiftUI

@main
struct AcmeShopApp: App {
  @State private var router = Router()

  init() {
    do {
      try Lander.initialize(apiKey: "pk_live_...")  // publishable key from the dashboard
    } catch {
      assertionFailure("Lander: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(router)
        .onOpenURL { Lander.handle(url: $0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { Lander.handle(userActivity: $0) }
        .task {
          for await link in Lander.deepLinks {
            router.open(link.route, link: link)
          }
        }
    }
  }
}
```

`initialize` returns at once: loading the install ID and the launch report (`POST /v1/sdk/init`) run in the background, so it never blocks startup on the network. It throws only for a key that is not a publishable key (`pk_test_...`, `pk_live_...`); secret keys are rejected because anything shipped in an app is public, and the error never contains the key.

### UIKit with a scene delegate

```swift
// AppDelegate
func application(
  _ application: UIApplication,
  didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
) -> Bool {
  try? Lander.initialize(apiKey: "pk_live_...")
  Lander.onDeepLink { link in
    Router.shared.open(link.route, link: link)
  }
  return true
}

// SceneDelegate
func scene(
  _ scene: UIScene, willConnectTo session: UISceneSession,
  options connectionOptions: UIScene.ConnectionOptions
) {
  // ... set up the window ...
  Lander.handle(connectionOptions: connectionOptions)  // the link that launched the app
}

func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
  for context in URLContexts { Lander.handle(url: context.url) }
}

func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
  Lander.handle(userActivity: userActivity)
}
```

### UIKit with an app delegate only

```swift
func application(
  _ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]
) -> Bool {
  Lander.handle(url: url)
}

func application(
  _ application: UIApplication, continue userActivity: NSUserActivity,
  restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
) -> Bool {
  Lander.handle(userActivity: userActivity)
}
```

`handle(url:)` takes every web and custom scheme URL (unknown links are still delivered, unresolved). If another SDK (sign in, payments) also handles URLs, give it the URL first.

### Receive links

`Lander.deepLinks` is an `AsyncStream<LanderLink>`; each access returns a new stream, so iterate it in one task. `Lander.onDeepLink { }` calls a closure on the main actor instead and returns a `LanderSubscription` (call `cancel()` to stop; releasing it does not). Links that arrive while nobody listens are buffered and replayed in order to the next listener; every listener gets every link.

`LanderLink` mirrors the API's `ResolvedLink`:

| Property | Meaning |
|---|---|
| `url` | The URL that opened the app, exactly as iOS delivered it |
| `linkId` | Lander link ID, or `nil` when the link is unknown to Lander |
| `shortURL` | Canonical short link, for example `https://acme.golander.link/p-123` |
| `path` | The in app route set on the link, for example `/product/123` |
| `route` | `path` when resolved, otherwise the raw URL's path and query |
| `params` | Link params (`[String: LanderParamValue]`), with the opened URL's query parameters merged over them |
| `campaign`, `channel` | Attribution labels set on the link |
| `isDeferred` | True when recovered after install or handed off after sign in |
| `confidence` | `.deterministic`, `.probabilistic` or `.unattributed` |
| `method` | `universal_link`, `landing_page`, `authenticated_handoff` or `probabilistic_match` |
| `isResolved` | Whether Lander recognized the link |

The launch link can also be read once with `await Lander.initialLink()`. It is the link handed to `handle` while the app launches (until about a second after it first becomes active), or on a first launch the deferred link. It is delivered once: through `initialLink()` if you ask before a stream delivered it, otherwise through the streams.

The same URL reported twice within 2 seconds (iOS can report a launch URL through more than one callback) counts once.

### Deferred deep links

A deferred deep link is a link someone tapped before the app was installed.

- **"Continue in app" page (deterministic).** When the project turns it on, iOS clicks see a page with an App Store button and an "I already have the app, open it" button. After installing, the user taps the second button; the app opens through your custom scheme and the link arrives with `method == "landing_page"` (and `isDeferred` when the app was installed after the click).
- **Authenticated handoff (deterministic).** Your server binds a link to a user with `POST /v1/handoffs`; the app claims it after sign in:

  ```swift
  let user = try await auth.signIn()
  if let link = try await Lander.claimHandoff(userId: user.id) {
    router.open(link.route, link: link)
  }
  ```

  The link is returned only, never also delivered on `deepLinks`. Use an ID that cannot be guessed (your auth system's user UUID, not an email address).
- **Probabilistic matching (opt in, off by default).** On first launch, recent iOS clicks that match the install's OS major version and country (or network, with IP matching on) may come back as a deferred link with `confidence == .probabilistic`. Treat it as a suggestion: land on the product page, never sign the user in or apply a credit on the strength of it.
- A link that opened the app always wins over a deferred one.

### Create links

```swift
do {
  let link = try await Lander.createLink(
    path: "/product/123",
    params: ["productId": "123"],
    title: "Trail runner",
    channel: "share"
  )
  share(link.url)
} catch let error as LanderError {
  // error.code, error.statusCode, error.message, error.retryAfter
}
```

The slug is random and the domain is the project's default domain. Requests are retried on network and server errors with the same `Idempotency-Key`, so a retry never creates two links. Retries wait at most 10 seconds in total: a longer `Retry-After` (and `link_quota_exceeded`) comes back as a `LanderError` with `retryAfter` instead.

### Track events

```swift
Lander.trackEvent("purchase", properties: ["amount": 49.99, "currency": "USD"], linkId: link?.linkId)
```

Fire and forget. Events are written to a queue on the device first and sent in batches of up to 100:

- They survive offline periods and app restarts (up to 1000 queued events; the oldest are dropped beyond that).
- They wait until the API knows the install (the first successful launch report).
- Failed batches are retried with exponential backoff (1 s doubling up to 5 min, with jitter, honoring `Retry-After`).
- Every event carries a client generated UUID, so a batch sent twice is counted once.
- The queue is flushed shortly after each event and when the app goes to the background (inside a background task).
- Events tracked before `initialize` wait for it.

An invalid event (empty name or over 100 characters, a `linkId` that is not a UUID, properties that are not strings, numbers, booleans, nil, arrays or dictionaries) is dropped with a warning in the log.

### Install ID and logging

`Lander.installID` is the random UUID created on first launch. It is stored in Application Support in a directory excluded from iCloud and device backups, so it is never restored onto another device, and it is gone when the app is uninstalled. If the API reports that the ID belongs to another project or environment (for example after switching from a `pk_test_` to a `pk_live_` key), the SDK creates a new one and reports a first launch.

`Lander.initialize(apiKey:enableLogging: true)` writes diagnostics to the unified log (subsystem `link.golander.lander`), visible in the Xcode console. The key is never logged.

## Privacy

- **Install ID only.** No device model, no IDFA, no fingerprint, no pasteboard access. No App Tracking Transparency prompt is needed.
- **What is sent:** the install ID, platform, app version, OS version, SDK version, the URLs that opened the app, the events you track, and the user ID you pass to `claimHandoff` (the API stores only a hash of it).
- The package ships a privacy manifest (`PrivacyInfo.xcprivacy`) declaring a device ID and product interaction data (analytics, not linked to the user) and the user ID passed to `claimHandoff` (app functionality, linked). Nothing is used for tracking. No required reason APIs are used.

## Local development

With the Lander monorepo running (`pnpm dev`), the API listens on port 8787. Use the seeded test key:

```swift
try Lander.initialize(
  apiKey: "pk_test_DemoPublishableKey000000000000",
  baseURL: URL(string: "http://localhost:8787")!,
  enableLogging: true
)
```

Plain HTTP needs `NSAllowsLocalNetworking` under `NSAppTransportSecurity` in a debug `Info.plist`. Open a link without tapping one:

```bash
xcrun simctl openurl booted "acmeshop://product/123"
xcrun simctl openurl booted "https://acme.golander.link/p-123"
```

A Universal Link only opens the app on the simulator when the domain's apple-app-site-association file is reachable; use the custom scheme to test routing locally.

## Developing the SDK

```bash
swift build
swift test
xcodebuild -scheme Lander -destination 'generic/platform=iOS Simulator' build
```

The core is platform independent and tested on macOS with a fake transport and platform; UIKit pieces sit behind `#if canImport(UIKit)`. Behavior follows the Flutter SDK (`sdk/lander_flutter`) in the Lander monorepo.

## API

The SDK only talks to Lander's public API (`/v1/sdk/init`, `/v1/sdk/resolve`, `/v1/sdk/events`, `/v1/sdk/links`, `/v1/sdk/handoffs/claim`) with the header `X-Lander-Sdk: ios/<version>`. Every request has a 10 second timeout; every write carries an `Idempotency-Key` that stays the same across retries.
