import Foundation

/// Delivers links to the app without losing or doubling any.
///
/// * Links that arrive while nobody listens are buffered and replayed, in order, to the next
///   listener. This covers cold starts and links that arrive before the app's router is ready.
/// * Every current listener gets every link.
/// * The link that launched the app is delivered exactly once: through ``takeInitialLink()``
///   when the app asks for it before a stream delivered it, otherwise through the streams. Later
///   ``takeInitialLink()`` calls return nil.
final class LinkDispatcher: @unchecked Sendable {
  private struct Pending {
    let link: LanderLink
    let initial: Bool
  }

  private let lock = NSLock()
  private var listeners: [UUID: AsyncStream<LanderLink>.Continuation] = [:]
  private var buffer: [Pending] = []
  private let initialGate = AsyncGate()
  private var settled = false
  private var initialLink: LanderLink?
  private var initialRequested = false
  private var initialOnStream = false
  private var initialTaken = false

  /// A new listener. It receives the buffered links first, then every new one, until the stream
  /// is cancelled or released.
  func stream() -> AsyncStream<LanderLink> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: LanderLink.self, bufferingPolicy: .unbounded)
    let id = UUID()
    continuation.onTermination = { [weak self] _ in self?.removeListener(id) }
    lock.lock()
    listeners[id] = continuation
    drainLocked()
    lock.unlock()
    return stream
  }

  var hasListeners: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !listeners.isEmpty
  }

  /// Whether the launch link is known (it may be nil).
  var initialSettled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return settled
  }

  /// Sets the link that launched the app. Only the first call counts; later links go to the
  /// streams.
  func setInitialLink(_ link: LanderLink?) {
    lock.lock()
    if settled {
      lock.unlock()
      if let link { add(link) }
      return
    }
    settled = true
    initialLink = link
    if let link, !initialRequested {
      emitLocked(Pending(link: link, initial: true))
    }
    lock.unlock()
    initialGate.open()
  }

  /// Delivers a link that arrived while the app was running.
  func add(_ link: LanderLink) {
    lock.lock()
    emitLocked(Pending(link: link, initial: false))
    lock.unlock()
  }

  /// Returns the launch link unless a stream or an earlier call already delivered it. Waits
  /// until the launch link is known.
  func takeInitialLink() async -> LanderLink? {
    markInitialRequested()
    // Not cancellable: giving up halfway would leave the launch link neither returned nor on
    // the streams.
    await initialGate.wait(cancellable: false)
    return claimInitialLink()
  }

  private func markInitialRequested() {
    lock.lock()
    initialRequested = true
    lock.unlock()
  }

  private func claimInitialLink() -> LanderLink? {
    lock.lock()
    defer { lock.unlock() }
    if initialOnStream || initialTaken { return nil }
    initialTaken = true
    buffer.removeAll { $0.initial }
    return initialLink
  }

  private func removeListener(_ id: UUID) {
    lock.lock()
    listeners[id] = nil
    lock.unlock()
  }

  private func emitLocked(_ pending: Pending) {
    if !listeners.isEmpty && buffer.isEmpty {
      deliverLocked(pending)
    } else {
      buffer.append(pending)
      drainLocked()
    }
  }

  private func drainLocked() {
    while !buffer.isEmpty && !listeners.isEmpty {
      deliverLocked(buffer.removeFirst())
    }
  }

  private func deliverLocked(_ pending: Pending) {
    if pending.initial {
      if initialRequested { return }
      initialOnStream = true
    }
    for listener in listeners.values { listener.yield(pending.link) }
  }
}
