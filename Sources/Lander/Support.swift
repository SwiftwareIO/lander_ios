import CryptoKit
import Foundation
import os

/// Version reported to the API as `sdkVersion` and in the `X-Lander-Sdk` header. Keep it in step
/// with `LanderSDK.podspec` and `CHANGELOG.md`.
let landerSDKVersion = "0.1.0"

/// A value guarded by a lock, readable from any thread.
final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: Value

  init(_ value: Value) { _value = value }

  var value: Value {
    lock.lock()
    defer { lock.unlock() }
    return _value
  }

  func set(_ value: Value) {
    lock.lock()
    _value = value
    lock.unlock()
  }

  @discardableResult
  func withLock<T>(_ body: (inout Value) -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body(&_value)
  }
}

/// A one shot gate: tasks wait until it opens, then every wait returns at once.
final class AsyncGate: @unchecked Sendable {
  private let lock = NSLock()
  private var opened = false
  private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

  var isOpen: Bool {
    lock.lock()
    defer { lock.unlock() }
    return opened
  }

  func open() {
    lock.lock()
    opened = true
    let pending = waiters
    waiters = [:]
    lock.unlock()
    for waiter in pending.values { waiter.resume() }
  }

  /// Waits until the gate opens. With `cancellable`, a cancelled task stops waiting early.
  func wait(cancellable: Bool = true) async {
    let id = UUID()
    if !cancellable {
      await withCheckedContinuation { enqueue(id, $0, cancelled: false) }
      return
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { enqueue(id, $0, cancelled: Task.isCancelled) }
    } onCancel: {
      lock.lock()
      let waiter = waiters.removeValue(forKey: id)
      lock.unlock()
      waiter?.resume()
    }
  }

  /// Waits until the gate opens or `timeout` seconds pass, whichever comes first.
  func wait(timeout: TimeInterval) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await self.wait() }
      group.addTask { try? await Task.sleep(nanoseconds: nanoseconds(timeout)) }
      await group.next()
      group.cancelAll()
    }
  }

  private func enqueue(_ id: UUID, _ waiter: CheckedContinuation<Void, Never>, cancelled: Bool) {
    lock.lock()
    if opened || cancelled {
      lock.unlock()
      waiter.resume()
      return
    }
    waiters[id] = waiter
    lock.unlock()
  }
}

func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
  seconds <= 0 ? 0 : UInt64(seconds * 1_000_000_000)
}

/// Prints SDK diagnostics to the unified log when logging is enabled. Never logs API keys.
struct LanderLogger: Sendable {
  let enabled: Bool
  private static let logger = Logger(subsystem: "link.golander.lander", category: "Lander")

  func log(_ message: @autoclosure () -> String) {
    guard enabled else { return }
    let text = message()
    Self.logger.debug("[Lander] \(text, privacy: .public)")
  }

  /// Integration mistakes (calls before `initialize`, invalid arguments to fire and forget
  /// calls). Logged even when logging is off, because nothing else would surface them.
  static func warn(_ message: String) {
    logger.error("[Lander] \(message, privacy: .public)")
  }
}

extension UUID {
  /// RFC 4122 URL namespace, as `Namespace.url` in the Dart `uuid` package.
  static let urlNamespace = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!

  /// A name based (version 5, SHA-1) UUID: the same name always gives the same ID.
  static func v5(namespace: UUID, name: String) -> UUID {
    var data = withUnsafeBytes(of: namespace.uuid) { Data($0) }
    data.append(Data(name.utf8))
    var bytes = Array(Insecure.SHA1.hash(data: data).prefix(16))
    bytes[6] = (bytes[6] & 0x0F) | 0x50
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  /// Lowercase, as the other Lander SDKs send IDs.
  var lowercased: String { uuidString.lowercased() }

  static func isValid(_ string: String) -> Bool { UUID(uuidString: string) != nil }
}

enum ISODate {
  static func format(_ date: Date) -> String {
    Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
  }

  static func parse(_ string: String) -> Date? {
    if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
      return date
    }
    return try? Date.ISO8601FormatStyle().parse(string)
  }
}
