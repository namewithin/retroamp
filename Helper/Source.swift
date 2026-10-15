import AppKit
import WebKit
import ObjectiveC

@MainActor final class StreamSource:NSObject,NSApplicationDelegate,WKNavigationDelegate {
    var web:WKWebView!,mediaWindow:NSWindow!
    let writer=CommandWriter(.standardOutput)
    var closing=false,active=false,initialDocumentReady=false
    private var pendingCommands=0
    private var documentGeneration=0
    func pid(_ name:String)->pid_t? {
        let selector=NSSelectorFromString(name)
        guard let web,web.responds(to:selector),let method=class_getInstanceMethod(type(of:web),selector)else{return nil}
        typealias Getter = @convention(c)(AnyObject,Selector)->Int32
        let value=unsafeBitCast(method_getImplementation(method),to:Getter.self)(web,selector)
        return value>0 ? value:nil
    }
    func reply(_ id:Int,_ result:[String:Any]=[:],error:String?=nil){var value:[String:Any]=["id":id,"result":result];if let error{value["error"]=error};writer.send(value)}
    func applicationDidFinishLaunching(_ n:Notification) {
        guard CommandLine.arguments.contains("--controlled-stream")else{NSApp.terminate(nil);return}
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent();config.mediaTypesRequiringUserActionForPlayback=[]
        config.userContentController.addUserScript(WKUserScript(source:Self.guardScript,injectionTime:.atDocumentStart,forMainFrameOnly:false))
        web=WKWebView(frame:NSRect(x:0,y:0,width:800,height:450),configuration:config);web.navigationDelegate=self
        web.customUserAgent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15 Retroamp/0.10"
        mediaWindow=NSWindow(contentRect:web.frame,styleMask:.borderless,backing:.buffered,defer:false)
        mediaWindow.alphaValue=0;mediaWindow.ignoresMouseEvents=true;mediaWindow.isReleasedWhenClosed=false
        mediaWindow.collectionBehavior=[.ignoresCycle,.transient];mediaWindow.contentView=web;mediaWindow.orderFrontRegardless()
        web.loadHTMLString("<html><head></head><body></body></html>",baseURL:nil)
        // WebKit requires a window attachment for media loading. Transparent, mouse-inert helper surface; never presents service UI.
        Task.detached{[weak self]in
            while let line=readLine(){guard line.utf8.count<=StreamFrames.limit,let bytes=line.data(using:.utf8),let value=try?JSONSerialization.jsonObject(with:bytes)as?[String:Any]else{continue};await self?.enqueue(value)}
            await self?.shutdown()
        }
    }
    func enqueue(_ value:[String:Any]) {
        guard !closing,let id=value["id"]as?Int else{return}
        guard pendingCommands<64 else{reply(id,error:"Too many pending IPC commands");return}
        pendingCommands+=1
        Task{@MainActor [self]in defer{pendingCommands-=1};await command(value)}
    }
    func command(_ value:[String:Any]) async {
        guard !closing,let id=value["id"]as? Int,let method=value["method"]as? String else{return}
        do {
            switch method {
            case "script":
                for _ in 0..<150{if initialDocumentReady || closing{break};try await Task.sleep(nanoseconds:20_000_000)}
                guard initialDocumentReady,!closing,let script=value["script"]as? String else{throw SourceFailure.invalid}
                web.configuration.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:true))
                _=try?await web.evaluateJavaScript(script);reply(id)
            case "evaluate":
                guard let script=value["expression"]as? String else{throw SourceFailure.invalid}
                // Direct WK execution avoids eval()/Trusted Types and resolves returned Promises.
                let result=try await web.callAsyncJavaScript("return await ("+script+"\n)",arguments:[:],in:nil,contentWorld:.page)
                reply(id,result as?[String:Any] ?? [:])
            case "execute":
                guard let script=value["expression"]as? String else{throw SourceFailure.invalid}
                let result=try await web.evaluateJavaScript(script);reply(id,result as?[String:Any] ?? [:])
            case "reload":web.reload();reply(id)
            case "navigate":
                guard let raw=value["url"]as? String,let url=URL(string:raw),url.scheme=="https",["music.youtube.com","www.youtube.com"].contains(url.host ?? "")else{throw SourceFailure.invalid}
                web.load(URLRequest(url:url));reply(id)
            case "cookies":
                var cookies:[HTTPCookie]=[]
                for row in value["cookies"]as?[[String:Any]] ?? []{
                    guard let name=row["name"]as?String,let val=row["value"]as?String,let domain=row["domain"]as?String,[".youtube.com","youtube.com","music.youtube.com",".music.youtube.com"].contains(domain)else{continue}
                    var props:[HTTPCookiePropertyKey:Any]=[.name:name,.value:val,.domain:domain,.path:row["path"]as?String ?? "/"]
                    if row["secure"]as?Bool==true{props[.secure]="TRUE"};if row["httpOnly"]as?Bool==true{props[HTTPCookiePropertyKey("HttpOnly")]="TRUE"}
                    if let expires=row["expires"]as?Double,expires>0{props[.expires]=Date(timeIntervalSince1970:expires)}
                    if let sameSite=row["sameSite"]as?String{props[HTTPCookiePropertyKey("SameSite")]=sameSite}
                    if let cookie=HTTPCookie(properties:props){cookies.append(cookie)}
                }
                for cookie in cookies{await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)}
                reply(id,["count":cookies.count])
            case "cookieInfo":
                let cookies=await web.configuration.websiteDataStore.httpCookieStore.allCookies()
                // Only diagnostics of explicitly synthetic fixtures may call this; never emit cookie values.
                reply(id,["cookies":cookies.map{["name":$0.name,"domain":$0.domain,"path":$0.path,"secure":$0.isSecure,"httpOnly":$0.isHTTPOnly,"expires":$0.expiresDate?.timeIntervalSince1970 ?? -1]as[String:Any]}])
            case "sourceInfo":
                var info:[String:Any]=["sourcePID":getpid(),"documentGeneration":documentGeneration,"nativePipeActive":active,"windowVisible":mediaWindow.isVisible]
                if let p=pid("_gpuProcessIdentifier"){info["gpuPID"]=p}
                if let p=pid("_webProcessIdentifier"){info["webPID"]=p}
                if !active {
                    let checked=try?await web.evaluateJavaScript("(()=>{const v=document.querySelector('video');if(!v)return false;v.pause();v.muted=false;v.volume=1;const safe=v.muted===true&&v.volume===0;v.muted=true;v.volume=0;return safe})()")
                    info["guardVerified"]=checked as? Bool==true
                }else{info["guardVerified"]=true}
                reply(id,info)
            case "activate":
                guard value["enabled"]as?Bool==true else{throw SourceFailure.invalid}
                guard value["documentGeneration"]as?Int==documentGeneration else{throw SourceFailure.navigation}
                let token=documentGeneration
                _=try await web.evaluateJavaScript("window.__retroNativePipe=true;({})")
                guard token==documentGeneration else{throw SourceFailure.navigation}
                guard !closing else{throw SourceFailure.invalid}
                active=true;reply(id,["documentGeneration":documentGeneration])
            case "shutdown":await shutdown()
            default:throw SourceFailure.invalid
            }
        }catch{reply(id,error:(error as NSError).userInfo["WKJavaScriptExceptionMessage"]as?String ?? error.localizedDescription)}
    }
    func shutdown()async {
        guard !closing else{return};closing=true;active=false
        let confirmed=try?await web.evaluateJavaScript("(()=>{window.__retroNativePipe=false;const media=[...document.querySelectorAll('video,audio')];media.forEach(v=>{v.muted=true;v.volume=0;v.pause()});return media.every(v=>v.muted&&v.volume===0&&v.paused)})()")
        writer.send(["quiet":confirmed as?Bool==true]);web.stopLoading();NSApp.terminate(nil)
    }
    func webView(_ webView:WKWebView,didCommit navigation:WKNavigation!){documentGeneration+=1;active=false}
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){initialDocumentReady=true}
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
        if action.targetFrame?.isMainFrame==true,let url=action.request.url,let host=url.host,!Set(["music.youtube.com","www.youtube.com"]).contains(host){decisionHandler(.cancel)}else{decisionHandler(.allow)}
    }
    enum SourceFailure:LocalizedError{case invalid,navigation;var errorDescription:String?{self == .navigation ? "navigation changed":"Invalid source command"}}
    static let guardScript = #"window.__retroNativePipe=false;(()=>{const p=HTMLMediaElement.prototype,v=Object.getOwnPropertyDescriptor(p,'volume'),m=Object.getOwnPropertyDescriptor(p,'muted');Object.defineProperty(p,'volume',{get:v.get,set(x){v.set.call(this,window.__retroNativePipe?Math.max(0,Math.min(0.01,x)):0)}});Object.defineProperty(p,'muted',{get:m.get,set(x){m.set.call(this,window.__retroNativePipe?!!x:true)}});const play=p.play;p.play=function(...args){this.muted=!window.__retroNativePipe;this.volume=window.__retroNativePipe?0.01:0;return play.apply(this,args)};document.addEventListener('play',e=>{if(e.target instanceof HTMLMediaElement){e.target.muted=!window.__retroNativePipe;e.target.volume=window.__retroNativePipe?0.01:0}},true)})()"#
}
@main struct SourceMain{@MainActor static func main(){let app=NSApplication.shared,source=StreamSource();app.setActivationPolicy(.accessory);app.delegate=source;app.run()}}
