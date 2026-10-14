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

enum KeychainSession {
    private static let query: [String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"local.retroamp.native",kSecAttrAccount as String:"youtube-music-session"]
    private static let marker="google-session-executable.v4"
    private static var executableID:String? {
        guard let path=Bundle.main.executableURL,let data=try? Data(contentsOf:path) else {return nil}
        return SHA256.hash(data:data).map {String(format:"%02x",$0)}.joined()
    }
    static func load(allowInteraction:Bool=false) throws -> SessionCredentials? {
        if !allowInteraction {guard let id=executableID,UserDefaults.standard.string(forKey:marker)==id else {return nil}}
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        let context=LAContext();context.interactionNotAllowed = !allowInteraction;q[kSecUseAuthenticationContext as String]=context
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status==errSecItemNotFound {return nil}
        guard status==errSecSuccess,let data=result as? Data else {throw MusicError.message("Натисніть GOOGLE, щоб підключити акаунт до цієї версії Retroamp.")}
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
        if let id=executableID {UserDefaults.standard.set(id,forKey:marker)}
    }
    static func delete() throws {
        let status=SecItemDelete(query as CFDictionary)
        guard status==errSecSuccess || status==errSecItemNotFound else {throw MusicError.message("Не вдалося видалити сесію з Keychain (\(status)).")}
        UserDefaults.standard.removeObject(forKey:marker)
    }
}

enum MusicError: LocalizedError {
    case message(String)
    var errorDescription:String? {switch self {case .message(let message):return message}}
}

struct MusicItem: Equatable {
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

enum MusicParser {
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
    init() {let c=URLSessionConfiguration.ephemeral;c.timeoutIntervalForRequest=25;c.timeoutIntervalForResource=40;c.httpShouldSetCookies=false;network=URLSession(configuration:c,delegate:networkDelegate,delegateQueue:nil)}
    func setSession(_ value:SessionCredentials?) {session=value}
    func search(_ query:String) async throws -> MusicPage {try await request("search",["query":query])}
    func browse(_ id:String) async throws -> MusicPage {try await request("browse",["browseId":id])}
    func more(_ token:String,endpoint:String) async throws -> MusicPage {try await request(endpoint,["continuation":token])}
    func authenticate(_ value:SessionCredentials) async throws -> MusicPage {
        try await request("browse",["browseId":"FEmusic_liked_playlists"],using:value)
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
        guard ["search","browse"].contains(endpoint) else {throw MusicError.message("Непідтримуваний запит.")}
        let cfg=try await context()
        var context=cfg["INNERTUBE_CONTEXT"] as? [String:Any] ?? [:]
        if var client=context["client"] as? [String:Any] {client["hl"]="uk";context["client"]=client}
        var components=URLComponents(string:"https://music.youtube.com/youtubei/v1/"+endpoint)!
        if let key=cfg["INNERTUBE_API_KEY"] as? String {components.queryItems=[URLQueryItem(name:"key",value:key)]}
        var body=payload;body["context"]=context
        var req=URLRequest(url:components.url!);req.httpMethod="POST";req.httpBody=try JSONSerialization.data(withJSONObject:body)
        req.setValue("application/json",forHTTPHeaderField:"Content-Type");req.setValue(agent,forHTTPHeaderField:"User-Agent");req.setValue("https://music.youtube.com",forHTTPHeaderField:"Origin");req.setValue("https://music.youtube.com",forHTTPHeaderField:"X-Origin");req.setValue("https://music.youtube.com/",forHTTPHeaderField:"Referer")
        let activeSession=override ?? session
        if let session=activeSession {req.setValue(session.cookie,forHTTPHeaderField:"Cookie");req.setValue(session.authorization(),forHTTPHeaderField:"Authorization");req.setValue(session.authUser,forHTTPHeaderField:"X-Goog-AuthUser");if let page=session.pageID {req.setValue(page,forHTTPHeaderField:"X-Goog-PageId")}}
        let (data,response)=try await network.data(for:req)
        guard let http=response as? HTTPURLResponse else {throw MusicError.message("Немає відповіді YouTube Music.")}
        guard http.statusCode == 200 else {throw MusicError.message(http.statusCode==401 || http.statusCode==403 ? "Сесія відхилена. Натисніть GOOGLE для входу." : "YouTube Music повернув HTTP \(http.statusCode).")}
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw MusicError.message("Непідтримувана відповідь YouTube Music.")}
        if object["error"] != nil {throw MusicError.message("YouTube Music відхилив запит.")}
        if activeSession != nil && !MusicParser.authenticated(object) {throw MusicError.message("Сесія закінчилася. Підключіть акаунт кнопкою GOOGLE.")}
        return MusicParser.page(object)
    }
}
