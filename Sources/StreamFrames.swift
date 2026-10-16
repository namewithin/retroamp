import Foundation

// Both ends are our own executables. Bound even malformed/partial JSON and fixture/video payloads.
final class StreamFrames:@unchecked Sendable {
    private let lock=NSLock()
    private var buffer=Data()
    static let limit=32*1024*1024
    func append(_ data:Data)->[[String:Any]] {
        lock.lock();defer{lock.unlock()}
        guard buffer.count+data.count<=Self.limit else{buffer.removeAll();return [["transportError":"IPC frame too large"]]}
        buffer.append(data);var result:[[String:Any]]=[]
        while let end=buffer.firstIndex(of:10){let line=buffer.prefix(upTo:end);if let value=try?JSONSerialization.jsonObject(with:line)as?[String:Any]{result.append(value)};buffer.removeSubrange(...end)}
        return result
    }
}
