import Foundation
import Security
import LocalAuthentication
import CryptoKit

struct BrowserCookie:Codable {
    let name:String,value:String,domain:String,path:String
    let secure:Bool,httpOnly:Bool
    let expires:Double
    let sameSite:String?
    var parameters:[String:Any] {
        var result:[String:Any]=["name":name,"value":value,"domain":domain,"path":path,"secure":secure,"httpOnly":httpOnly]
        if expires>0 {result["expires"]=expires}
        if let sameSite,["Strict","Lax","None"].contains(sameSite) {result["sameSite"]=sameSite}
        return result
    }
}
struct SessionCredentials: Codable {
    let cookie: String
    let authUser: String
    let pageID: String?
    var browserCookies:[BrowserCookie]? = nil
    static func parse(_ input: String) throws -> SessionCredentials {
        guard input.utf8.count <= 200_000 else {throw MusicError.message("Дані сесії надто великі.")}
        var headers: [String:String] = [:]
        if let data=input.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            for (key,value) in object {if let string=value as? String {headers[key.lowercased()]=string}}
        } else {
            var pending: String?
            for raw in input.components(separatedBy:.newlines) {
                let line=raw.trimmingCharacters(in:.whitespacesAndNewlines)
                if line.isEmpty || line.hasPrefix(":") {continue}
                if let colon=line.firstIndex(of:":") {
                    let key=String(line[..<colon]).lowercased()
                    let value=String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
                    if value.isEmpty {pending=key} else {headers[key]=value;pending=nil}
                } else if let key=pending {headers[key]=line;pending=nil}
            }
            if headers["cookie"] == nil && input.contains("SAPISID=") && !input.contains("\n") {headers["cookie"]=input.trimmingCharacters(in:.whitespaces)}
        }
        guard let cookie=headers["cookie"],!cookie.isEmpty,!cookie.contains("\r"),!cookie.contains("\n") else {throw MusicError.message("Google ще не передав сесію YouTube Music. Завершіть вхід у відкритому вікні.")}
        let values=cookieValues(cookie)
        guard let secret=values["SAPISID"] ?? values["__Secure-3PAPISID"],!secret.isEmpty else {throw MusicError.message("Сесію Google ще не підключено. Завершіть вхід у YouTube Music.")}
        let authUser=headers["x-goog-authuser"] ?? "0"
        guard Int(authUser) != nil,authUser.count<=5 else {throw MusicError.message("Некоректний номер акаунта X-Goog-AuthUser.")}
        let pageID=headers["x-goog-pageid"]
        guard pageID?.contains(where: {$0.isNewline}) != true else {throw MusicError.message("Некоректний X-Goog-PageId.")}
        return SessionCredentials(cookie:cookie,authUser:authUser,pageID:pageID)
    }
    static func cookieValues(_ raw: String) -> [String:String] {
        var result: [String:String]=[:]
        for pair in raw.split(separator:";") {
            guard let equal=pair.firstIndex(of:"=") else {continue}
            let name=pair[..<equal].trimmingCharacters(in:.whitespaces)
            let value=String(pair[pair.index(after:equal)...]).trimmingCharacters(in:.whitespaces)
            if !name.isEmpty {result[name]=value}
        }
        return result
    }
    func authorization(timestamp: Int = Int(Date().timeIntervalSince1970)) -> String {
        let cookies=Self.cookieValues(cookie)
        let secret=cookies["SAPISID"] ?? cookies["__Secure-3PAPISID"] ?? ""
        let input="\(timestamp) \(secret) https://music.youtube.com"
        let hash=Insecure.SHA1.hash(data:Data(input.utf8)).map {String(format:"%02x",$0)}.joined()
        return "SAPISIDHASH \(timestamp)_\(hash)"
    }
}

@MainActor enum KeychainSession {
    private static let query: [String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.retroamp.native",kSecAttrAccount as String:"youtube-music-session"]
    private static let marker="google-session-executable.v4"
    typealias Reader=@MainActor ([String:Any])->(OSStatus,Data?)
    static func readItem(_ query:[String:Any])->(OSStatus,Data?) {
        var result:CFTypeRef?;let status=SecItemCopyMatching(query as CFDictionary,&result)
        return (status,result as? Data)
    }
    static func load(allowInteraction:Bool=false,reader:Reader=readItem) throws -> SessionCredentials? {
        return try loadItem(query,allowInteraction:allowInteraction,reader:reader)
    }
    static func loadItem(_ query:[String:Any],allowInteraction:Bool,reader:Reader=readItem) throws -> SessionCredentials? {
        // Existing macOS file-based Keychain items ignore LAContext's UI policy.
        // Serialize this process-wide legacy switch on MainActor and restore it after reading.
        var previous:DarwinBoolean=false
        let previousStatus=SecKeychainGetUserInteractionAllowed(&previous)
        guard previousStatus==errSecSuccess else {throw MusicError.message("Не вдалося перевірити доступ до Keychain (\(previousStatus)).")}
        let interactionStatus=SecKeychainSetUserInteractionAllowed(allowInteraction)
        guard interactionStatus==errSecSuccess else {throw MusicError.message("Не вдалося налаштувати запит до Keychain (\(interactionStatus)).")}
        defer {_=SecKeychainSetUserInteractionAllowed(previous.boolValue)}
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        let context=LAContext();context.interactionNotAllowed = !allowInteraction;q[kSecUseAuthenticationContext as String]=context
        let (status,data)=reader(q)
        if status==errSecItemNotFound {return nil}
        if status==errSecInteractionNotAllowed || status==errSecAuthFailed || status==errSecUserCanceled {throw SessionAccessError.authorizationRequired}
        guard status==errSecSuccess,let data else {throw MusicError.message("Не вдалося прочитати сесію з Keychain (\(status)). Збережений вхід не видалено.")}
        return try JSONDecoder().decode(SessionCredentials.self,from:data)
    }
    static func save(_ credentials: SessionCredentials) throws {
        let data=try JSONEncoder().encode(credentials)
        let status=SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status==errSecItemNotFound {
            var q=query;q[kSecValueData as String]=data;q[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added=SecItemAdd(q as CFDictionary,nil)
            guard added==errSecSuccess else {throw MusicError.message("Не вдалося зберегти сесію в Keychain (\(added)).")}
        } else if status != errSecSuccess {throw MusicError.message("Не вдалося оновити сесію в Keychain (\(status)).")}
        UserDefaults.standard.removeObject(forKey:marker)
    }
    static func delete() throws {
        let status=SecItemDelete(query as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else {throw MusicError.message("Не вдалося видалити сесію з Keychain (\(status)).")}
        UserDefaults.standard.removeObject(forKey:marker)
    }
}

enum SessionAccessError:LocalizedError {
    case authorizationRequired
    var errorDescription:String? {"Keychain потребує дозволу для цієї збірки. Натисніть GOOGLE → «Відновити збережений вхід» і дозвольте доступ у вікні macOS. Повторний вхід у Google не потрібен, якщо сесія ще чинна."}
}

enum MusicError: LocalizedError {
    case message(String)
    var errorDescription:String? {switch self {case .message(let message):return message}}
}

struct MusicItem: Equatable,Codable {
    let id: String
    let title: String
    let subtitle: String
    let videoID: String?
    let browseID: String?
    let duration: String
    var localURL:URL? = nil
    var isPlayable:Bool {videoID != nil || localURL != nil}
    var line: String {title+(subtitle.isEmpty ? "" : " — "+subtitle)}
}
struct MusicPage {let items:[MusicItem];let continuation:String?}

struct VideoRendition:Sendable {
    struct Segment:Sendable {let from:Double,to:Double,duration:Double}
    let videoID:String
    let segments:[Segment]
    func originalTime(for time:Double)->Double {
        let inverse=segments.sorted {$0.to<$1.to}
        guard let s=inverse.first(where:{time >= $0.to && time < $0.to+$0.duration}) ?? inverse.last(where:{time >= $0.to}) ?? inverse.first else {return time}
        return max(0,s.from+min(s.duration,max(0,time-s.to)))
    }
    var parameters:[String:Any] {["id":videoID,"segments":segments.map {["from":$0.from,"to":$0.to,"duration":$0.duration]}]}
}

enum MusicParser {
    // Only an explicit service pairing for the requested recording is accepted.
    static func videoRendition(_ object:[String:Any],for id:String)->VideoRendition? {
        for wrapper in descendants(object,key:"playlistPanelVideoWrapperRenderer").compactMap({$0 as? [String:Any]}) {
            guard let primary=(wrapper["primaryRenderer"] as? [String:Any])?["playlistPanelVideoRenderer"] as? [String:Any] else {continue}
            for other in wrapper["counterpart"] as? [[String:Any]] ?? [] {
                guard let counterpart=(other["counterpartRenderer"] as? [String:Any])?["playlistPanelVideoRenderer"] as? [String:Any] else {continue}
                let primaryID=primary["videoId"] as? String,otherID=counterpart["videoId"] as? String
                let reversed=otherID==id
                guard primaryID==id || reversed else {continue}
                let target=reversed ? primary : counterpart
                guard let targetID=target["videoId"] as? String,targetID != id,targetID.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else {continue}
                let type=descendants(target["navigationEndpoint"] ?? [:],key:"musicVideoType").compactMap {$0 as? String}.first
                guard type=="MUSIC_VIDEO_TYPE_OMV" || type=="MUSIC_VIDEO_TYPE_UGC" else {continue}
                let segments=((other["segmentMap"] as? [String:Any])?["segment"] as? [[String:Any]] ?? []).compactMap { row -> VideoRendition.Segment? in
                    func number(_ key:String)->Double? {if let n=row[key] as? Double {return n/1000};return (row[key] as? String).flatMap(Double.init).map {$0/1000}}
                    guard let a=number("primaryVideoStartTimeMilliseconds"),let b=number("counterpartVideoStartTimeMilliseconds"),let d=number("durationMilliseconds"),a.isFinite,b.isFinite,d.isFinite,a>=0,b>=0,d>0 else {return nil}
                    return .init(from:reversed ? b:a,to:reversed ? a:b,duration:d)
                }.sorted {$0.from<$1.from}
                return VideoRendition(videoID:targetID,segments:segments)
            }
        }
        return nil
    }

    static func runs(_ value: Any?) -> String {
        guard let value=value as? [String:Any] else {return ""}
        if let text=value["simpleText"] as? String {return text}
        return (value["runs"] as? [[String:Any]] ?? []).compactMap {$0["text"] as? String}.joined()
    }
    static func descendants(_ value: Any, key: String) -> [Any] {
        var result:[Any]=[]
        func visit(_ node:Any) {
            if let dict=node as? [String:Any] {
                if let found=dict[key] {result.append(found)}
                for (name,child) in dict where name != key {visit(child)}
            } else if let array=node as? [Any] {for child in array {visit(child)}}
        }
        visit(value);return result
    }
    static func authenticated(_ object:[String:Any])->Bool {
        guard let context=object["responseContext"] as? [String:Any] else {return false}
        for service in context["serviceTrackingParams"] as? [[String:Any]] ?? [] {
            for param in service["params"] as? [[String:Any]] ?? [] {
                if let key=param["key"] as? String,["logged_in","yt_li"].contains(key),let value=param["value"] as? String {
                    return value=="1" || value=="true"
                }
            }
        }
        if let web=context["mainAppWebResponseContext"] as? [String:Any],let loggedOut=web["loggedOut"] as? Bool {return !loggedOut}
        return false
    }
    static func page(_ object: [String:Any]) -> MusicPage {
        var items:[MusicItem]=[],seen:Set<String>=[]
        func parse(_ row:[String:Any]) {
            let columns=(row["flexColumns"] as? [[String:Any]] ?? []).map {runs(($0["musicResponsiveListItemFlexColumnRenderer"] as? [String:Any])?["text"])}
            let title=columns.first ?? runs(row["title"])
            guard !title.isEmpty else {return}
            let firstColumn=((row["flexColumns"] as? [[String:Any]])?.first?["musicResponsiveListItemFlexColumnRenderer"] as? [String:Any])?["text"] as? [String:Any]
            let firstRun=(firstColumn?["runs"] as? [[String:Any]])?.first
            let titleRun=((row["title"] as? [String:Any])?["runs"] as? [[String:Any]])?.first
            let primary=row["navigationEndpoint"] ?? firstRun?["navigationEndpoint"] ?? titleRun?["navigationEndpoint"] ?? [:]
            let videoID=(row["playlistItemData"] as? [String:Any])?["videoId"] as? String ?? descendants(primary,key:"watchEndpoint").compactMap {($0 as? [String:Any])?["videoId"] as? String}.first
            let browseID=descendants(primary,key:"browseEndpoint").compactMap {($0 as? [String:Any])?["browseId"] as? String}.first
            let playlistID=descendants(primary,key:"watchPlaylistEndpoint").compactMap {($0 as? [String:Any])?["playlistId"] as? String}.first
            let browse=browseID ?? playlistID.map {"VL"+$0}
            let validVideo=videoID.flatMap { $0.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil ? $0 : nil }
            // Collection rows often contain a preview/play button; browsing must win over that preview.
            let isCollection=browse != nil && !(row["playlistItemData"] is [String:Any]) && validVideo == nil
            let chosenVideo=isCollection ? nil : validVideo
            guard chosenVideo != nil || browse != nil else {return}
            let id=chosenVideo ?? browse!
            guard !seen.contains(id) else {return};seen.insert(id)
            let duration=(row["fixedColumns"] as? [[String:Any]] ?? []).map {runs(($0["musicResponsiveListItemFixedColumnRenderer"] as? [String:Any])?["text"])}.first ?? ""
            items.append(MusicItem(id:id,title:title,subtitle:columns.count>1 ? columns[1] : runs(row["subtitle"]),videoID:chosenVideo,browseID:chosenVideo == nil ? browse : nil,duration:duration))
        }
        func visit(_ node:Any) {
            if let dict=node as? [String:Any] {
                if let row=dict["musicResponsiveListItemRenderer"] as? [String:Any] {parse(row);return}
                if let row=dict["musicTwoRowItemRenderer"] as? [String:Any] {parse(row);return}
                // Rendered contents live in ordered arrays. Visit contents before ancillary metadata.
                if let contents=dict["contents"] {visit(contents)}
                for key in dict.keys.sorted() where key != "contents" && key != "menu" {if let child=dict[key] {visit(child)}}
            } else if let array=node as? [Any] {for child in array {visit(child)}}
        }
        visit(object)
        let continuation=descendants(object,key:"nextContinuationData").compactMap {($0 as? [String:Any])?["continuation"] as? String}.first ?? descendants(object,key:"continuationCommand").compactMap {($0 as? [String:Any])?["token"] as? String}.first
        return MusicPage(items:items,continuation:continuation)
    }
}

final class MusicNetworkDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) {
        completionHandler(request.url?.scheme=="https" && request.url?.host=="music.youtube.com" ? request : nil)
    }
}

actor MusicService {
    private var config: [String:Any]?
    private var session: SessionCredentials?
    private let agent="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private let network:URLSession
    private let networkDelegate=MusicNetworkDelegate()
    init(config:[String:Any]?=nil,network:URLSession?=nil) {self.config=config;let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=25;c.timeoutIntervalForResource=40;c.httpShouldSetCookies=false;self.network=network ?? URLSession(configuration:c,delegate:networkDelegate,delegateQueue:nil)}
    func setSession(_ value:SessionCredentials?) {session=value}
    func videoRendition(_ id:String) async throws -> VideoRendition? {
        guard id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else {return nil}
        let object=try await requestObject("next",["videoId":id,"playlistId":"RDAMVM"+id,"enablePersistentPlaylistPanel":true,"isAudioOnly":true,"tunerSettingValue":"AUTOMIX_SETTING_NORMAL","watchEndpointMusicSupportedConfigs":["watchEndpointMusicConfig":["hasPersistentPlaylistPanel":true,"musicVideoType":"MUSIC_VIDEO_TYPE_ATV"]]])
        return MusicParser.videoRendition(object,for:id)
    }
    func search(_ query:String) async throws -> MusicPage {try await request("search",["query":query])}
    func browse(_ id:String) async throws -> MusicPage {try await request("browse",["browseId":id])}
    func more(_ token:String,endpoint:String) async throws -> MusicPage {try await request(endpoint,["continuation":token])}
    func authenticate(_ value:SessionCredentials) async throws -> MusicPage {
        try await request("browse",["browseId":"FEmusic_liked_playlists"],using:value)
    }
    func like(_ id:String) async throws {
        guard session != nil else {throw MusicError.message("Увійдіть через Google, щоб додати трек до улюблених.")}
        guard id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else {throw MusicError.message("Некоректний ідентифікатор треку.")}
        let result=try await requestObject("like/like",["target":["videoId":id]])
        guard result["status"] as? String=="STATUS_SUCCEEDED" else {throw MusicError.message("YouTube Music не підтвердив додавання до улюблених.")}
    }
    private func context() async throws -> [String:Any] {
        if let config {return config}
        var req=URLRequest(url:URL(string:"https://music.youtube.com/")!);req.setValue(agent,forHTTPHeaderField:"User-Agent")
        let (data,response)=try await network.data(for:req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,let html=String(data:data,encoding:.utf8) else {throw MusicError.message("Не вдалося отримати конфігурацію YouTube Music.")}
        let regex=try NSRegularExpression(pattern:"ytcfg\\.set\\((\\{.*?\\})\\);",options:[.dotMatchesLineSeparators])
        let ns=html as NSString
        for match in regex.matches(in:html,range:NSRange(location:0,length:ns.length)) {
            let raw=ns.substring(with:match.range(at:1))
            if let bytes=raw.data(using:.utf8),let object=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],object["INNERTUBE_CONTEXT"] != nil {config=object;return object}
        }
        throw MusicError.message("YouTube Music змінив конфігурацію; потрібне оновлення клієнта.")
    }
    private func request(_ endpoint:String,_ payload:[String:Any],using override:SessionCredentials? = nil) async throws -> MusicPage {
        MusicParser.page(try await requestObject(endpoint,payload,using:override))
    }
    private func requestObject(_ endpoint:String,_ payload:[String:Any],using override:SessionCredentials? = nil) async throws -> [String:Any] {
        guard ["search","browse","like/like","next"].contains(endpoint) else {throw MusicError.message("Непідтримуваний запит.")}
        let activeSession=override ?? session
        let cfg=try await context()
        try Task.checkCancellation()
        var context=cfg["INNERTUBE_CONTEXT"] as? [String:Any] ?? [:]
        if var client=context["client"] as? [String:Any] {client["hl"]="uk";context["client"]=client}
        var components=URLComponents(string:"https://music.youtube.com/youtubei/v1/"+endpoint)!
        if let key=cfg["INNERTUBE_API_KEY"] as? String {components.queryItems=[URLQueryItem(name:"key",value:key)]}
        var body=payload;body["context"]=context
        var req=URLRequest(url:components.url!);req.httpMethod="POST";req.httpBody=try JSONSerialization.data(withJSONObject:body)
        req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.setValue(agent,forHTTPHeaderField:"User-Agent");req.setValue("https://music.youtube.com",forHTTPHeaderField:"Origin");req.setValue("https://music.youtube.com",forHTTPHeaderField:"X-Origin");req.setValue("https://music.youtube.com/",forHTTPHeaderField:"Referer")
        if let session=activeSession {req.setValue(session.cookie,forHTTPHeaderField:"Cookie");req.setValue(session.authorization(),forHTTPHeaderField:"Authorization");req.setValue(session.authUser,forHTTPHeaderField:"X-Goog-AuthUser");if let page=session.pageID {req.setValue(page,forHTTPHeaderField:"X-Goog-PageId")}}
        let (data,response)=try await network.data(for:req)
        guard let http=response as? HTTPURLResponse else {throw MusicError.message("Немає відповіді YouTube Music.")}
        guard http.statusCode == 200 else {throw MusicError.message(http.statusCode==401 || http.statusCode==403 ? "Сесія відхилена. Натисніть GOOGLE для входу." : "YouTube Music повернув HTTP \(http.statusCode).")}
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw MusicError.message("Непідтримувана відповідь YouTube Music.")}
        if object["error"] != nil {throw MusicError.message("YouTube Music відхилив запит.")}
        if activeSession != nil && !MusicParser.authenticated(object) {throw MusicError.message("Сесія закінчилася. Підключіть акаунт кнопкою GOOGLE.")}
        return object
    }
}
