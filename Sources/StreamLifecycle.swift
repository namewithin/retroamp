import Foundation
import Darwin

/// JSON lines use one throwing write; EOF and repeated close are normal lifecycle events.
final class CommandWriter {
    private let handle: FileHandle
    private var closed = false
    private let lock = NSLock()
    init(_ handle: FileHandle) { self.handle = handle; signal(SIGPIPE, SIG_IGN) }
    @discardableResult func send(_ value: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, var data = try? JSONSerialization.data(withJSONObject: value) else { return false }
        data.append(10)
        do { try handle.write(contentsOf: data); return true }
        catch { closed = true; try? handle.close(); return false }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true; try? handle.close()
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
