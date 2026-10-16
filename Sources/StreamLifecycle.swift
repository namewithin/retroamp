import Foundation
import Darwin

/// Enqueue JSON lines without blocking the caller on a stalled helper/reader.
final class CommandWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "local.retroamp.ipc-writer")
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let maximumQueuedBytes: Int
    private let maximumQueuedMessages: Int
    private let nonblocking: Bool
    private var sealed = false, queuedBytes = 0, queuedMessages = 0
    // Only the serial worker touches the handle or finished state after init.
    private var finished = false

    init(_ handle: FileHandle, timeout: TimeInterval = 2,
         maximumQueuedBytes: Int = 32 * 1024 * 1024, maximumQueuedMessages: Int = 64) {
        self.handle = handle
        self.timeout = timeout.isFinite && timeout > 0 ? min(timeout, 30) : 2
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
        self.maximumQueuedMessages = max(1, maximumQueuedMessages)
        signal(SIGPIPE, SIG_IGN)
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        nonblocking = flags >= 0 && fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// True means accepted; completion reports the eventual write result off-main.
    @discardableResult func send(_ value: [String: Any], completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: value) else { return false }
        data.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        lock.lock(); defer { lock.unlock() }
        guard !sealed, nonblocking, data.count <= maximumQueuedBytes - queuedBytes,
              queuedMessages < maximumQueuedMessages else { return false }
        queuedBytes += data.count; queuedMessages += 1
        // Dispatch while holding the short state lock so close cannot overtake accepted data.
        queue.async { [self, data] in
            let success = !finished && write(data, deadline: deadline)
            lock.lock()
            queuedBytes -= data.count; queuedMessages -= 1
            if !success { sealed = true }
            lock.unlock()
            // A partial JSON frame must never be followed by another frame after failure.
            if !success { finish() }
            completion(success)
        }
        return true
    }

    /// Seal immediately, then drain accepted frames within their original deadlines.
    func close(completion: @escaping () -> Void = {}) {
        lock.lock(); defer { lock.unlock() }
        sealed = true
        queue.async { [self] in finish(); completion() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true; try? handle.close()
    }

    private func write(_ data: Data, deadline: TimeInterval) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var offset = 0
            while offset < bytes.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let count = Darwin.write(handle.fileDescriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0 && errno == EINTR { continue }
                guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else { return false }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return false }
                var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, Int32(max(1, min(50, ceil(remaining * 1000)))))
                if ready < 0 && errno != EINTR { return false }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
            }
            return true
        }
    }
}

/// A stopped startup cannot cross any subsequent hardware or source-unmute boundary.
@MainActor final class StartupLifecycle {
    private var task: Task<Void, Never>?
    private(set) var stopping = false
    func start(_ operation: @escaping () async throws -> Void, onError: @escaping (Error) -> Void) {
        guard task == nil, !stopping else { return }
        task = Task {
            do { try checkActive(); try await operation() }
            catch is CancellationError { }
            catch { if !stopping { onError(error) } }
        }
    }
    func checkActive() throws {
        try Task.checkCancellation()
        if stopping { throw CancellationError() }
    }
    func stop() { stopping = true; task?.cancel() }
}
