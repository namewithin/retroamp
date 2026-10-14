import Foundation
import Darwin

// Only an ephemeral Retroamp-owned profile is controlled. No regular browser profiles are accessed.
@MainActor final class CDPConnection {
    private let socket:URLSessionWebSocketTask
    private var reader:Task<Void,Never>?
    private var pending:[Int:CheckedContinuation<[String:Any],Error>]=[:]
    private var nextID=0
    private var closed=false
    var isOpen:Bool {!closed}
    init(url:URL,network:URLSession) {
        socket=network.webSocketTask(with:url);socket.resume()
        reader=Task { [weak self] in
            while let self,!self.closed {
                do {
                    let message=try await self.socket.receive(),data:Data
                    switch message {case .data(let d):data=d;case .string(let s):data=Data(s.utf8);@unknown default:continue}
                    guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],let id=object["id"] as? Int,let continuation=self.pending.removeValue(forKey:id) else {continue}
                    if object["error"] != nil {continuation.resume(throwing:MusicError.message("Помилка потокового рушія."))} else {continuation.resume(returning:object["result"] as? [String:Any] ?? [:])}
                } catch {self.close();break}
            }
        }
    }
    func call(_ method:String,_ params:[String:Any]=[:]) async throws -> [String:Any] {
        guard !closed else {throw MusicError.message("Потоковий рушій закрито.")}
        nextID+=1;let id=nextID
        let data=try JSONSerialization.data(withJSONObject:["id":id,"method":method,"params":params])
        let watchdog=Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds:8_000_000_000)
            if !Task.isCancelled,let continuation=self?.pending.removeValue(forKey:id) {continuation.resume(throwing:MusicError.message("Потоковий рушій не відповів."))}
        }
        defer {watchdog.cancel()}
        return try await withCheckedThrowingContinuation {continuation in
            pending[id]=continuation
            Task { @MainActor [weak self] in
                guard let self else {return}
                do {try await socket.send(.string(String(decoding:data,as:UTF8.self)))} catch {pending.removeValue(forKey:id)?.resume(throwing:error)}
            }
        }
    }
    func evaluate(_ expression:String) async throws -> [String:Any] {
        let response=try await call("Runtime.evaluate",["expression":expression,"returnByValue":true,"userGesture":true,"awaitPromise":true])
        guard response["exceptionDetails"]==nil else {throw MusicError.message("Не вдалося виконати дію плеєра.")}
        return (response["result"] as? [String:Any])?["value"] as? [String:Any] ?? [:]
    }
    func close() {
        guard !closed else {return};closed=true;reader?.cancel();reader=nil;socket.cancel(with:.goingAway,reason:nil)
        let waiting=pending.values;pending.removeAll();for c in waiting {c.resume(throwing:MusicError.message("Потоковий рушій закрито."))}
    }
}

@MainActor final class ChromiumHost {
    private var process:Process?
    private var profile:URL?
    private var port=0
    var connection:CDPConnection?
    private let network:URLSession = {
        let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=2
        return URLSession(configuration:c)
    }()
    func start(script:String) async throws -> CDPConnection {
        if let connection {return connection}
        let executable=URL(fileURLWithPath:"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw MusicError.message("Встановіть Google Chrome для потокового відтворення та входу Google.")}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("retroamp-stream-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);profile=directory
        port=try availableLoopbackPort()
        let p=Process();p.executableURL=executable
        p.arguments=["--headless=new","--user-data-dir="+directory.path,"--remote-debugging-port=\(port)","--remote-debugging-address=127.0.0.1","--no-first-run","--no-default-browser-check","--disable-background-mode","--disable-background-timer-throttling","--disable-renderer-backgrounding","--autoplay-policy=no-user-gesture-required","about:blank"]
        if CommandLine.arguments.contains("--verify") || CommandLine.arguments.contains("--check-audio") || CommandLine.arguments.contains("--quiet") {p.arguments?.append("--mute-audio")}
        p.standardError=FileHandle.nullDevice;p.standardOutput=FileHandle.nullDevice
        p.terminationHandler={_ in try? FileManager.default.removeItem(at:directory)}
        try p.run();process=p
        do {
            for _ in 0..<80 {
                try Task.checkCancellation()
                guard p.isRunning,process===p else {throw MusicError.message("Потоковий рушій закрито.")}
                if let data=try? await network.data(from:URL(string:"http://127.0.0.1:\(port)/json/list")!).0,let pages=try? JSONSerialization.jsonObject(with:data) as? [[String:Any]],let page=pages.first(where:{$0["type"] as? String=="page"}),let endpoint=page["webSocketDebuggerUrl"] as? String,let url=URL(string:endpoint),url.host=="127.0.0.1",url.port==port {
                    let c=CDPConnection(url:url,network:network);connection=c
                    let version=try await c.call("Browser.getVersion")
                    let ua=(version["userAgent"] as? String ?? "").replacingOccurrences(of:"HeadlessChrome",with:"Chrome")
                    _=try await c.call("Network.setUserAgentOverride",["userAgent":ua])
                    _=try await c.call("Page.enable")
                    _=try await c.call("Page.addScriptToEvaluateOnNewDocument",["source":script])
                    return c
                }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            throw MusicError.message("Не вдалося запустити потоковий рушій.")
        } catch {close();throw error}
    }
    func close() {
        connection?.close();connection=nil
        if let process,process.isRunning {process.terminate()}
        process=nil;profile=nil
    }
}

func availableLoopbackPort() throws -> Int {
    let fd=Darwin.socket(AF_INET,SOCK_STREAM,0);guard fd>=0 else {throw MusicError.message("Не вдалося підготувати підключення.")};defer {Darwin.close(fd)}
    var a=sockaddr_in();a.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);a.sin_family=sa_family_t(AF_INET);a.sin_addr.s_addr=inet_addr("127.0.0.1")
    let bound=withUnsafePointer(to:&a) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
    guard bound==0 else {throw MusicError.message("Не вдалося підготувати підключення.")}
    var length=socklen_t(MemoryLayout<sockaddr_in>.size)
    let result=withUnsafeMutablePointer(to:&a) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&length)}}
    guard result==0 else {throw MusicError.message("Не вдалося підготувати підключення.")}
    return Int(UInt16(bigEndian:a.sin_port))
}
