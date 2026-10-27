## 0.1.0

First release of the native iOS SDK, with the behavior of the Flutter SDK 0.3.0:

* `Lander.initialize(apiKey:baseURL:enableLogging:)` validates the publishable key (secret keys are rejected, the key is never echoed) and returns at once; the launch report runs in the background.
* Universal Links and custom scheme URLs through `Lander.handle(url:)`, `handle(userActivity:)`, `handle(connectionOptions:)` and `handle(launchOptions:)`, for SwiftUI, scene delegate and app delegate apps.
* `Lander.deepLinks` (`AsyncStream`) and `Lander.onDeepLink { }`, with buffering and replay, plus `Lander.initialLink()` delivered once.
* Deferred links on first launch (a launch link wins), the Continue in app page's `lander_link` parameter, `install_id_conflict` recovery.
* `Lander.createLink(...)`, `Lander.claimHandoff(userId:)` and `Lander.trackEvent(_:properties:linkId:)` with a persistent, batched event queue.
* Storage in Application Support, excluded from backups. Privacy manifest included.
* Swift Package `Lander` and CocoaPods pod `LanderSDK`.
