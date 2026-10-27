import Foundation

#if canImport(UIKit)
  import UIKit
#endif

/// Facts about the host app sent with `POST /v1/sdk/init`. Deliberately small: no device model,
/// no locale, no advertising identifiers.
struct LanderPlatformInfo: Sendable, Equatable {
  /// `ios` (the API also knows `android`). Anything else skips the launch report.
  let platform: String
  let appVersion: String
  let osVersion: String?
}

/// App lifecycle moments the SDK reacts to.
enum LanderLifecycleEvent: Sendable {
  /// The launch has settled: the app became active and the URL or activity that launched it
  /// (if any) has been delivered. Links handled after this are not the launch link.
  case launchSettled

  /// The app moved to the background. Call `finish` once the work it triggers is done, so the
  /// platform can end the background task it started.
  case didEnterBackground(finish: @Sendable () -> Void)

  /// The app is about to come back to the foreground.
  case willEnterForeground
}

/// What the SDK needs from the OS. ``SystemPlatform`` in apps, a fake in tests.
protocol LanderPlatform: Sendable {
  func platformInfo() -> LanderPlatformInfo

  /// Small key value storage kept out of device backups, so the install ID and event queue
  /// never move to another device.
  func read(_ key: String) throws -> String?
  func write(_ key: String, _ value: String) throws
  func delete(_ key: String) throws

  func lifecycleEvents() -> AsyncStream<LanderLifecycleEvent>
}

/// The real platform: files in Application Support, UIKit notifications.
struct SystemPlatform: LanderPlatform {
  let storage: FileStorage

  /// Seconds after the app first becomes active during which a handled link still counts as the
  /// launch link. SwiftUI delivers the launch URL to `onOpenURL` around activation.
  var launchGrace: TimeInterval = 1

  init(storage: FileStorage = FileStorage(directoryName: "lander")) {
    self.storage = storage
  }

  func platformInfo() -> LanderPlatformInfo {
    let appVersion =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    #if os(iOS)
      let platform = "ios"
    #else
      let platform = "macos"
    #endif
    return LanderPlatformInfo(
      platform: platform, appVersion: appVersion, osVersion: Self.osVersion())
  }

  /// `18.1` or `17.4.1`, from ProcessInfo (no main thread hop, unlike `UIDevice`).
  static func osVersion() -> String {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    var text = "\(version.majorVersion).\(version.minorVersion)"
    if version.patchVersion > 0 { text += ".\(version.patchVersion)" }
    return text
  }

  func read(_ key: String) throws -> String? { try storage.read(key) }
  func write(_ key: String, _ value: String) throws { try storage.write(key, value) }
  func delete(_ key: String) throws { try storage.delete(key) }

  func lifecycleEvents() -> AsyncStream<LanderLifecycleEvent> {
    #if canImport(UIKit) && !os(watchOS)
      let grace = launchGrace
      return AsyncStream { continuation in
        Task { @MainActor in
          let observer = LifecycleObserver(continuation: continuation, grace: grace)
          continuation.onTermination = { _ in
            Task { @MainActor in observer.stop() }
          }
          observer.start()
        }
      }
    #else
      // No app lifecycle to observe (the macOS build exists for tests).
      return AsyncStream { continuation in
        continuation.yield(.launchSettled)
      }
    #endif
  }
}

#if canImport(UIKit) && !os(watchOS)
  @MainActor
  private final class LifecycleObserver {
    private let continuation: AsyncStream<LanderLifecycleEvent>.Continuation
    private let grace: TimeInterval
    private var tokens: [NSObjectProtocol] = []
    private var launchSettled = false

    init(continuation: AsyncStream<LanderLifecycleEvent>.Continuation, grace: TimeInterval) {
      self.continuation = continuation
      self.grace = grace
    }

    func start() {
      let center = NotificationCenter.default
      tokens = [
        center.addObserver(
          forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.becameActive() }
        },
        center.addObserver(
          forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.enteredBackground() }
        },
        center.addObserver(
          forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { _ = self?.continuation.yield(.willEnterForeground) }
        },
      ]
      // initialize may run after the app became active (a late call). Treat that as the
      // activation.
      if UIApplication.shared.applicationState == .active { becameActive() }
    }

    func stop() {
      for token in tokens { NotificationCenter.default.removeObserver(token) }
      tokens = []
    }

    private func becameActive() {
      guard !launchSettled else { return }
      launchSettled = true
      // Scheduled on the main queue, so URL callbacks UIKit queued for the launch run first.
      let continuation = self.continuation
      DispatchQueue.main.asyncAfter(deadline: .now() + grace) {
        continuation.yield(.launchSettled)
      }
    }

    private func enteredBackground() {
      let task = BackgroundTask()
      continuation.yield(.didEnterBackground(finish: { Task { @MainActor in task.end() } }))
    }
  }

  /// A UIKit background task that gives the event queue time to flush. Ends once.
  @MainActor
  private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
      id = UIApplication.shared.beginBackgroundTask(withName: "Lander events") { [weak self] in
        MainActor.assumeIsolated { self?.end() }
      }
    }

    func end() {
      guard id != .invalid else { return }
      UIApplication.shared.endBackgroundTask(id)
      id = .invalid
    }
  }
#endif

/// Small files in Application Support, in a directory excluded from backups, so the install ID
/// is never restored onto another device.
final class FileStorage: @unchecked Sendable {
  private let directoryName: String
  private let baseDirectory: URL?
  private let lock = NSLock()
  private static let keyPattern = try! NSRegularExpression(pattern: "^[a-z0-9_]{1,64}$")

  /// `baseDirectory` overrides Application Support (tests).
  init(directoryName: String, baseDirectory: URL? = nil) {
    self.directoryName = directoryName
    self.baseDirectory = baseDirectory
  }

  struct InvalidKey: Error {}

  func read(_ key: String) throws -> String? {
    try access(key) { file in
      guard let data = try? Data(contentsOf: file) else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }

  func write(_ key: String, _ value: String) throws {
    _ = try access(key) { file in
      try Data(value.utf8).write(to: file, options: .atomic)
      return nil
    }
  }

  func delete(_ key: String) throws {
    _ = try access(key) { file in
      if FileManager.default.fileExists(atPath: file.path) {
        try FileManager.default.removeItem(at: file)
      }
      return nil
    }
  }

  private func access(_ key: String, _ op: (URL) throws -> String?) throws -> String? {
    guard
      Self.keyPattern.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    else { throw InvalidKey() }
    lock.lock()
    defer { lock.unlock() }
    return try op(try directory().appendingPathComponent(key))
  }

  /// The storage directory, created on demand.
  func directory() throws -> URL {
    let base =
      try baseDirectory
      ?? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    var dir = base.appendingPathComponent(directoryName, isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    // Checked on every access, not only on creation: the flag can be lost when the directory is
    // restored or migrated, and the install ID must never move to another device.
    if (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup != true
    {
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try dir.setResourceValues(values)
    }
    return dir
  }
}
