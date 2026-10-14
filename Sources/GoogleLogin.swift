import AppKit
import Darwin

// The browser profile belongs only to this sign-in attempt. Regular Chrome/Safari profiles are never read.
@MainActor
final class GoogleLogin {
    private var process:Process?
    private var directory:URL?
    private var webSocket:URLSessionWebSocketTask?
    private var nextID=0
    private var debugPort=0
    private let network:URLSession = {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest=5
        return URLSession(configuration:configuration)
    }()
    var onStatus:((String)->Void)?
    func start() throws {
        guard process==nil else {return}
        let executable=URL(fileURLWithPath:"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw MusicError.message("Для входу потрібен Google Chrome. Встановіть його з google.com/chrome й натисніть Google ще раз.")}
        let profile=FileManager.default.temporaryDirectory.appendingPathComponent("retroamp-google-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:profile,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        try FileManager.default.createDirectory(at:profile.appendingPathComponent("Default"),withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        debugPort=try Self.availablePort()
        let preferences:[String:Any] = ["credentials_enable_service":false,"profile":["password_manager_enabled":false],"browser":["check_default_browser":false]]
        let data=try JSONSerialization.data(withJSONObject:preferences)
        try data.write(to:profile.appendingPathComponent("Default/Preferences"))
        let p=Process();p.executableURL=executable
        p.arguments=["--user-data-dir="+profile.path,"--remote-debugging-port=\(debugPort)","--remote-debugging-address=127.0.0.1","--no-first-run","--no-default-browser-check","--disable-background-mode","--mute-audio","--window-size=560,720","https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F"]
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        p.terminationHandler={_ in try? FileManager.default.removeItem(at:profile)}
        do {try p.run();process=p;directory=profile} catch {try? FileManager.default.removeItem(at:profile);throw MusicError.message("Не вдалося відкрити Google Chrome для входу.")}
        onStatus?("Увійдіть у Google у відкритому вікні. Retroamp підключиться автоматично.")
    }
    func signIn(service:MusicService) async throws -> (SessionCredentials,MusicPage) {
        try start()
        let deadline=Date().addingTimeInterval(600)
        var lastValidation=Date.distantPast
        while Date()<deadline {
            try Task.checkCancellation()
            guard process?.isRunning==true,directory != nil else {throw MusicError.message("Вікно входу закрите. Натисніть Google, щоб повторити.")}
            if debugPort>0 {
                let port=debugPort
                if let candidate=try? await candidate(port:port),Date().timeIntervalSince(lastValidation)>3 {
                    lastValidation=Date()
                    onStatus?("Перевіряю підключення вашої бібліотеки…")
                    if let page=try? await service.authenticate(candidate) {try Task.checkCancellation();return (candidate,page)}
                    onStatus?("Завершіть вхід у Google у відкритому вікні.")
                }
            }
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        throw MusicError.message("Час очікування входу минув. Натисніть Google, щоб повторити.")
    }
    private func candidate(port:Int) async throws -> SessionCredentials {
        let (data,_)=try await network.data(from:URL(string:"http://127.0.0.1:\(port)/json/list")!)
        guard let pages=try JSONSerialization.jsonObject(with:data) as? [[String:Any]],let page=pages.first(where:{($0["type"] as? String)=="page" && ($0["url"] as? String).flatMap(URL.init(string:))?.host=="music.youtube.com"}),let endpoint=page["webSocketDebuggerUrl"] as? String,let url=URL(string:endpoint),url.host=="127.0.0.1",url.port==port else {throw MusicError.message("Очікую завершення входу…")}
        webSocket?.cancel(with:.goingAway,reason:nil)
        let socket=network.webSocketTask(with:url);webSocket=socket;socket.resume()
        defer {socket.cancel(with:.goingAway,reason:nil);if webSocket===socket {webSocket=nil}}
        let cookiesResult=try await command("Network.getCookies",parameters:["urls":["https://music.youtube.com/"]],socket:socket)
        let contextResult=try await command("Runtime.evaluate",parameters:["expression":"({host:location.hostname,authUser:String(window.ytcfg?.get('SESSION_INDEX')??0),pageID:window.ytcfg?.get('DELEGATED_SESSION_ID')||null})","returnByValue":true],socket:socket)
        guard let result=contextResult["result"] as? [String:Any],let context=result["value"] as? [String:Any],context["host"] as? String=="music.youtube.com",let cookies=cookiesResult["cookies"] as? [[String:Any]] else {throw MusicError.message("Очікую YouTube Music…")}
        return try Self.credentials(cookies:cookies,authUser:context["authUser"] as? String ?? "0",pageID:context["pageID"] as? String)
    }
    static func credentials(cookies:[[String:Any]],authUser:String,pageID:String?) throws -> SessionCredentials {
        let values=cookies.compactMap {cookie -> String? in
            guard let name=cookie["name"] as? String,let value=cookie["value"] as? String,let domain=cookie["domain"] as? String,[".youtube.com","youtube.com","music.youtube.com",".music.youtube.com"].contains(domain),!name.contains(where:{$0.isNewline || $0==";"}),!value.contains(where:{$0.isNewline || $0==";"}) else {return nil}
            return "\(name)=\(value)"
        }
        let headers:[String:String] = ["Cookie":values.joined(separator:"; "),"X-Goog-AuthUser":authUser].merging(pageID.map {["X-Goog-PageId":$0]} ?? [:],uniquingKeysWith:{$1})
        let data=try JSONSerialization.data(withJSONObject:headers)
        var credentials=try SessionCredentials.parse(String(data:data,encoding:.utf8)!)
        credentials.browserCookies=cookies.compactMap {cookie in
            guard let name=cookie["name"] as? String,let value=cookie["value"] as? String,let domain=cookie["domain"] as? String,[".youtube.com","youtube.com","music.youtube.com",".music.youtube.com"].contains(domain),!name.contains(where:{$0.isNewline || $0==";"}),!value.contains(where:{$0.isNewline || $0==";"}) else {return nil}
            return BrowserCookie(name:name,value:value,domain:domain,path:cookie["path"] as? String ?? "/",secure:cookie["secure"] as? Bool ?? true,httpOnly:cookie["httpOnly"] as? Bool ?? false,expires:cookie["expires"] as? Double ?? -1,sameSite:cookie["sameSite"] as? String)
        }
        return credentials
    }
    private func command(_ method:String,parameters:[String:Any],socket:URLSessionWebSocketTask) async throws -> [String:Any] {
        nextID+=1;let id=nextID
        let bytes=try JSONSerialization.data(withJSONObject:["id":id,"method":method,"params":parameters])
        let watchdog=Task { @MainActor in
            try? await Task.sleep(nanoseconds:5_000_000_000)
            if !Task.isCancelled {socket.cancel(with:.goingAway,reason:nil)}
        }
        defer {watchdog.cancel()}
        try await socket.send(.string(String(decoding:bytes,as:UTF8.self)))
        for _ in 0..<40 {
            let message=try await socket.receive(),data:Data
            switch message {case .data(let bytes):data=bytes;case .string(let string):data=Data(string.utf8);@unknown default:throw MusicError.message("Помилка підключення Google.")}
            guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {continue}
            if object["id"] as? Int==id {guard object["error"]==nil,let result=object["result"] as? [String:Any] else {throw MusicError.message("Google-вхід не завершився.")};return result}
        }
        throw MusicError.message("Google-вхід не відповів.")
    }
    func checkBrowser() async throws -> [String:Any] {
        let fixture:[[String:Any]]=[
            ["name":"SAPISID","value":"synthetic-test-value","domain":".youtube.com"],
            ["name":"HSID","value":"synthetic-http-only","domain":"music.youtube.com","path":"/account","secure":true,"httpOnly":true,"expires":2000000000.0,"sameSite":"Strict"],
            ["name":"UNRELATED","value":"excluded","domain":".google.com"]]
        let parsed=try Self.credentials(cookies:fixture,authUser:"2",pageID:"fixture-channel")
        let parserPass=parsed.authUser=="2" && parsed.pageID=="fixture-channel" && !parsed.cookie.contains("UNRELATED") && parsed.cookie.contains("HSID=")
        let roundTrip=try JSONDecoder().decode(SessionCredentials.self,from:JSONEncoder().encode(parsed))
        let scoped=roundTrip.browserCookies?.first(where:{$0.name=="HSID"})
        let attributes=scoped?.domain=="music.youtube.com" && scoped?.path=="/account" && scoped?.httpOnly==true && scoped?.secure==true && scoped?.expires==2000000000 && scoped?.sameSite=="Strict"
        let legacy=try JSONDecoder().decode(SessionCredentials.self,from:Data("{\"cookie\":\"SAPISID=fixture\",\"authUser\":\"0\",\"pageID\":null}".utf8))
        let legacyReadable=legacy.browserCookies==nil
        try start();defer {cancel()}
        var last:[String:Any]=[:]
        for _ in 0..<60 {
            try Task.checkCancellation()
            if let data=try? await network.data(from:URL(string:"http://127.0.0.1:\(debugPort)/json/list")!).0,let pages=try? JSONSerialization.jsonObject(with:data) as? [[String:Any]],let page=pages.first(where:{($0["url"] as? String).flatMap(URL.init(string:))?.host=="accounts.google.com"}),let endpoint=page["webSocketDebuggerUrl"] as? String,let url=URL(string:endpoint) {
                let socket=network.webSocketTask(with:url);webSocket=socket;socket.resume()
                let response=try await command("Runtime.evaluate",parameters:["expression":"({host:location.hostname,webdriver:navigator.webdriver,emailField:!!document.querySelector('#identifierId'),blocked:/browser or app may not be secure/i.test(document.body?.innerText||'')})","returnByValue":true],socket:socket)
                let value=(response["result"] as? [String:Any])?["value"] as? [String:Any] ?? [:]
                last=value
                let normalBrowser=(value["webdriver"] as? Bool)==false
                let pageReached=value["host"] as? String=="accounts.google.com"
                let formReady=value["emailField"] as? Bool==true
                let notBlocked=value["blocked"] as? Bool==false
                if pageReached && formReady && notBlocked {
                    _=try await command("Network.setCookies",parameters:["cookies":roundTrip.browserCookies!.map(\.parameters)],socket:socket)
                    let own=try await command("Network.getCookies",parameters:["urls":["https://music.youtube.com/account/check"]],socket:socket)
                    let other=try await command("Network.getCookies",parameters:["urls":["https://www.youtube.com/account/check"]],socket:socket)
                    let restored=(own["cookies"] as? [[String:Any]])?.first(where:{$0["name"] as? String=="HSID"})
                    let scopedOut=(other["cookies"] as? [[String:Any]] ?? []).allSatisfy {$0["name"] as? String != "HSID"}
                    let browserRoundTrip=restored?["httpOnly"] as? Bool==true && restored?["path"] as? String=="/account" && restored?["sameSite"] as? String=="Strict" && scopedOut
                    return ["passed":parserPass && normalBrowser && attributes && legacyReadable && browserRoundTrip,"googlePageReached":pageReached,"emailFormPresent":formReady,"automationFlag":value["webdriver"] ?? "unknown","youtubeCookieScope":parserPass,"cookieAttributesPreserved":attributes,"browserCookieRestoreVerified":browserRoundTrip,"legacySessionReadable":legacyReadable,"keychainTouched":false,"realAccountSignInVerified":false]
                }
                socket.cancel(with:.goingAway,reason:nil);webSocket=nil
            }
            try await Task.sleep(nanoseconds:500_000_000)
        }
        return ["passed":false,"lastPage":last,"googlePageReached":false,"keychainTouched":false,"realAccountSignInVerified":false]
    }
    private static func availablePort() throws -> Int {
        let fd=Darwin.socket(AF_INET,SOCK_STREAM,0)
        guard fd>=0 else {throw MusicError.message("Не вдалося підготувати вхід Google.")}
        defer {Darwin.close(fd)}
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr.s_addr=inet_addr("127.0.0.1")
        let status=withUnsafePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
        guard status==0 else {throw MusicError.message("Не вдалося підготувати вхід Google.")}
        var length=socklen_t(MemoryLayout<sockaddr_in>.size)
        let result=withUnsafeMutablePointer(to:&address) {$0.withMemoryRebound(to:sockaddr.self,capacity:1) {getsockname(fd,$0,&length)}}
        guard result==0 else {throw MusicError.message("Не вдалося підготувати вхід Google.")}
        return Int(UInt16(bigEndian:address.sin_port))
    }
    func cancel() {webSocket?.cancel(with:.goingAway,reason:nil);webSocket=nil;if let process,process.isRunning {process.terminate()};process=nil;directory=nil}
}
