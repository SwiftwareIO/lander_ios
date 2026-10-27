// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Lander",
  // macOS is declared so the core can be tested with `swift test` on a Mac. The SDK reports
  // launches only on iOS.
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "Lander", targets: ["Lander"])
  ],
  targets: [
    .target(
      name: "Lander",
      resources: [.copy("PrivacyInfo.xcprivacy")]
    ),
    .testTarget(
      name: "LanderTests",
      dependencies: ["Lander"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
