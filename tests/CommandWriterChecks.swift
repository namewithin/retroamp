import Foundation
import Darwin

private final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(_ value: Bool) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [Bool] { lock.lock(); defer { lock.unlock() }; return values }
}

@main struct CommandWriterChecks {
    @MainActor static func main() async {
        var checks: [String: Bool] = [:]
        let pipe = Pipe(), outcomes = Outcomes()
        let writer = CommandWriter(pipe.fileHandleForWriting, timeout: 0.15, maximumQueuedMessages: 2)
        let filled = [UInt8](repeating: 120, count: 4096).withUnsafeBytes { bytes -> Bool in
            for _ in 0..<1024 {
                let count = Darwin.write(pipe.fileHandleForWriting.fileDescriptor, bytes.baseAddress, bytes.count)
                if count < 0 { return errno == EAGAIN || errno == EWOULDBLOCK }
            }
            return false
        }
        checks["realUnreadPipeIsFull"] = filled
        let start = ProcessInfo.processInfo.systemUptime
        let accepted = writer.send(["id": 1]) { outcomes.record($0) }
        checks["sendReturnsWithoutWaitingForReader"] = accepted && ProcessInfo.processInfo.systemUptime - start < 0.1
        checks["secondFrameAcceptedWithinQueueLimit"] = writer.send(["id": 2]) { outcomes.record($0) }
        checks["inFlightFrameCountsTowardQueueLimit"] = !writer.send(["id": 3])
        var heartbeat = false
        Task { @MainActor in heartbeat = true }
        try? await Task.sleep(nanoseconds: 25_000_000)
        checks["mainActorRunsWhilePipeIsStalled"] = heartbeat
        let closeStart = ProcessInfo.processInfo.systemUptime
        writer.close()
        checks["closeDoesNotWaitForStalledWrite"] = ProcessInfo.processInfo.systemUptime - closeStart < 0.1
        await withCheckedContinuation { ready in writer.close { ready.resume() } }
        checks["deadlineEndsAllAcceptedFrames"] = outcomes.snapshot() == [false, false] && ProcessInfo.processInfo.systemUptime - start < 1.5
        checks["failedWriterRejectsFurtherFrames"] = !writer.send(["id": 4])
        try? pipe.fileHandleForReading.close()

        let normal = Pipe(), normalOutcomes = Outcomes()
        let reader = Task.detached { normal.fileHandleForReading.readDataToEndOfFile() }
        let healthy = CommandWriter(normal.fileHandleForWriting)
        let payload = String(repeating: "abc", count: 70_000) // Larger than PIPE_BUF.
        let first = healthy.send(["id": 1, "payload": payload]) { normalOutcomes.record($0) }
        let second = healthy.send(["id": 2]) { normalOutcomes.record($0) }
        let quiet = healthy.send(["quiet": true]) { normalOutcomes.record($0) }
        await withCheckedContinuation { ready in healthy.close { ready.resume() } }
        let received = await reader.value
        let frames = received.split(separator: 10).compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        checks["fifoFramesSurvivePartialWrites"] = first && second && quiet && frames.count == 3 && frames[0]["id"] as? Int == 1 && frames[1]["id"] as? Int == 2
        checks["largePayloadIsComplete"] = frames.first?["payload"] as? String == payload
        checks["quietAcknowledgementArrivesBeforeExit"] = frames.last?["quiet"] as? Bool == true && normalOutcomes.snapshot() == [true, true, true]
        checks["closedWriterRejectsNewFrames"] = !healthy.send(["id": 3])
        try? normal.fileHandleForReading.close()

        let small = Pipe(), bounded = CommandWriter(small.fileHandleForWriting, maximumQueuedBytes: 32)
        checks["oversizedFrameIsRejected"] = !bounded.send(["payload": String(repeating: "x", count: 100)])
        await withCheckedContinuation { ready in bounded.close { ready.resume() } }
        try? small.fileHandleForReading.close()

        let broken = Pipe(), brokenOutcomes = Outcomes()
        try? broken.fileHandleForReading.close()
        let disconnected = CommandWriter(broken.fileHandleForWriting)
        _ = disconnected.send(["id": 1]) { brokenOutcomes.record($0) }
        await withCheckedContinuation { ready in disconnected.close { ready.resume() } }
        checks["readerEOFReportsFailureWithoutSIGPIPE"] = brokenOutcomes.snapshot() == [false]
        let passed = checks.values.allSatisfy { $0 }
        checks["passed"] = passed
        let data = try! JSONSerialization.data(withJSONObject: checks, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(passed ? 0 : 1)
    }
}
