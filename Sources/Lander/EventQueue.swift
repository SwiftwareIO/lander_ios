import Foundation

/// Persistent, deduplicating event queue.
///
/// Events are stored before they are sent, sent in batches of up to `batchSize`, and removed
/// only after the API accepts them. Retryable failures back off exponentially; events keep their
/// client generated `id`, so a batch that is re-sent after a lost response is deduplicated by the
/// API.
actor EventQueue {
  typealias Event = [String: JSONValue]

  /// Sends one batch. Throws ``LanderError`` on failure.
  typealias Sender = @Sendable ([Event]) async throws -> Void

  static let storageKey = "event_queue"

  private let read: @Sendable (String) throws -> String?
  private let write: @Sendable (String, String) throws -> Void
  private let logger: LanderLogger
  let batchSize: Int

  /// Oldest events are dropped beyond this size so a long offline period cannot grow storage
  /// without bound.
  let maxQueueSize: Int

  /// Delay between an ``add(_:)`` and the flush it schedules, so bursts of events go out as one
  /// batch.
  let flushDelay: TimeInterval
  let backoff: Backoff

  private var sender: Sender?
  private var events: [Event] = []
  private var ids: Set<String> = []
  private var loaded = false
  private var flushing: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var timerGeneration = 0
  private var failures = 0
  private var halted = false
  private var disposed = false

  init(
    read: @escaping @Sendable (String) throws -> String?,
    write: @escaping @Sendable (String, String) throws -> Void,
    logger: LanderLogger,
    batchSize: Int = 100,
    maxQueueSize: Int = 1000,
    flushDelay: TimeInterval = 2,
    backoff: Backoff = Backoff()
  ) {
    self.read = read
    self.write = write
    self.logger = logger
    self.batchSize = batchSize
    self.maxQueueSize = maxQueueSize
    self.flushDelay = flushDelay
    self.backoff = backoff
  }

  func setSender(_ sender: @escaping Sender) { self.sender = sender }

  /// Events waiting to be sent, oldest first.
  var pending: [Event] {
    load()
    return events
  }

  /// Loads the persisted queue. Safe to call more than once.
  func load() {
    guard !loaded else { return }
    loaded = true
    do {
      guard let raw = try read(Self.storageKey), !raw.isEmpty else { return }
      guard let stored = JSONValue.decode(Data(raw.utf8))?.array else { return }
      for case .object(let event) in stored where event["id"]?.string != nil {
        insert(event)
      }
      logger.log("Loaded \(events.count) queued events")
    } catch {
      logger.log("Could not load the event queue, starting empty: \(error)")
    }
  }

  /// Adds `event` (which must have a unique string `id`) and schedules a flush. Events with an
  /// `id` that is already queued are ignored.
  func add(_ event: Event) {
    load()
    guard insert(event) else { return }
    while events.count > maxQueueSize {
      let dropped = events.removeFirst()
      if let id = dropped["id"]?.string { ids.remove(id) }
    }
    persist()
    schedule(flushDelay)
  }

  @discardableResult
  private func insert(_ event: Event) -> Bool {
    guard let id = event["id"]?.string, ids.insert(id).inserted else { return false }
    events.append(event)
    return true
  }

  /// Sends everything that is queued now. Concurrent calls share one flush.
  func flush() async {
    if let flushing {
      await flushing.value
      return
    }
    let task = Task {
      await runFlush()
      flushing = nil
    }
    flushing = task
    await task.value
  }

  private func runFlush() async {
    load()
    timer?.cancel()
    timer = nil
    while !events.isEmpty && !halted && !disposed {
      guard let sender else { return }
      let batch = Array(events.prefix(batchSize))
      defer { persist() }
      do {
        try await sender(batch)
        failures = 0
        remove(batch)
        logger.log("Sent \(batch.count) events")
      } catch let error as LanderError {
        if error.isRetryable {
          var wait = backoff.delay(failures)
          failures += 1
          if let retryAfter = error.retryAfter, retryAfter > wait { wait = retryAfter }
          logger.log("Event batch failed (\(error.code)), retrying in \(Int(wait))s")
          schedule(wait, retry: true)
          return
        }
        if error.statusCode == 401 || error.statusCode == 403 {
          // A bad key will not fix itself. Keep the events for the next launch.
          logger.log(
            "Event batch rejected (\(error.code)): check the API key. Pausing until next launch.")
          halted = true
          return
        }
        // Validation errors: the batch will never be accepted, drop it so it does not block the
        // queue forever.
        logger.log(
          "Dropping \(batch.count) events rejected by the API (\(error.code)): \(error.message)")
        remove(batch)
      } catch {
        logger.log("Event batch failed unexpectedly: \(error)")
        schedule(backoff.delay(failures), retry: true)
        failures += 1
        return
      }
    }
  }

  private func remove(_ batch: [Event]) {
    let sent = Set(batch.compactMap { $0["id"]?.string })
    events.removeAll { sent.contains($0["id"]?.string ?? "") }
    ids.subtract(sent)
  }

  /// Schedules a flush. A pending timer (a scheduled flush or a backoff) is kept, so new events
  /// never cut a backoff short; a `retry` replaces it.
  private func schedule(_ delay: TimeInterval, retry: Bool = false) {
    if disposed || halted { return }
    if timer != nil && !retry { return }
    timer?.cancel()
    timerGeneration += 1
    let generation = timerGeneration
    timer = Task { [weak self] in
      try? await Task.sleep(nanoseconds: nanoseconds(delay))
      if Task.isCancelled { return }
      await self?.timerFired(generation)
    }
  }

  private func timerFired(_ generation: Int) async {
    guard generation == timerGeneration else { return }
    timer = nil
    await flush()
  }

  private func persist() {
    do {
      let data = try JSONValue.array(events.map(JSONValue.object)).encoded()
      try write(Self.storageKey, String(decoding: data, as: UTF8.self))
    } catch {
      logger.log("Could not persist the event queue: \(error)")
    }
  }

  func dispose() {
    disposed = true
    timer?.cancel()
    timer = nil
  }
}
