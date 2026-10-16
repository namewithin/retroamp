import AppKit

enum VideoQuality:String,CaseIterable {
    case auto,hd720,hd1080
    var title:String {switch self {case .auto:return "AUTO";case .hd720:return "720p";case .hd1080:return "1080p"}}
    static func load()->VideoQuality {VideoQuality(rawValue:UserDefaults.standard.string(forKey:"video.quality") ?? "auto") ?? .auto}
    func save() {UserDefaults.standard.set(rawValue,forKey:"video.quality")}
}
struct VideoQualityState {
    let width:Int,height:Int
    let available:[String]
    let requested:VideoQuality
    let actual:String
    init(state:[String:Any],requested:VideoQuality) {
        let geometry=state["videoGeometry"] as? [String:Any] ?? [:]
        width=geometry["width"] as? Int ?? 0;height=geometry["height"] as? Int ?? 0
        available=state["availableQualities"] as? [String] ?? [];actual=state["quality"] as? String ?? "auto";self.requested=requested
    }
    var label:String {
        guard height>0 else {return "АУДІО · очікую відео"}
        let decoded="\(width)×\(height)"
        if requested != .auto,!available.isEmpty,!available.contains(requested.rawValue) {return "\(requested.title) недоступне · \(decoded)"}
        if requested != .auto,actual != requested.rawValue {return "До \(requested.title) · зараз \(decoded)"}
        return (requested == .auto ? "AUTO · " : "")+decoded
    }
}
