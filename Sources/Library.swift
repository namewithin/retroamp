import Foundation

struct LocalImportResult {
    var tracks:[MusicItem]=[]
    var unreadable:[String]=[]
}

enum LocalImporter {
    static let extensions:Set<String>=["mp3","m4a","aac","wav","wave","aiff","aif","flac","caf"]
    // Skip links and packages so a folder cannot create a recursive traversal cycle.
    static func collect(_ roots:[URL]) -> LocalImportResult {
        var result=LocalImportResult(),seen=Set<String>()
        let keys:Set<URLResourceKey>=[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]
        func add(_ url:URL) {
            guard extensions.contains(url.pathExtension.lowercased()),
                  let values=try? url.resourceValues(forKeys:keys),values.isRegularFile==true,values.isSymbolicLink != true else {return}
            let url=url.standardizedFileURL,id=url.absoluteString
            guard seen.insert(id).inserted else {return}
            result.tracks.append(MusicItem(id:id,title:url.deletingPathExtension().lastPathComponent,subtitle:url.deletingLastPathComponent().lastPathComponent,videoID:nil,browseID:nil,duration:"",localURL:url))
        }
        for root in roots where root.isFileURL {
            let scoped=root.startAccessingSecurityScopedResource()
            defer {if scoped {root.stopAccessingSecurityScopedResource()}}
            guard let values=try? root.resourceValues(forKeys:keys) else {result.unreadable.append(root.lastPathComponent);continue}
            if values.isDirectory==true,values.isSymbolicLink != true {
                guard let walker=FileManager.default.enumerator(at:root,includingPropertiesForKeys:Array(keys),options:[.skipsHiddenFiles,.skipsPackageDescendants],errorHandler:{url,_ in result.unreadable.append(url.lastPathComponent);return true}) else {result.unreadable.append(root.lastPathComponent);continue}
                var files:[URL]=[]
                for case let url as URL in walker {
                    if (try? url.resourceValues(forKeys:keys).isSymbolicLink)==true {walker.skipDescendants();continue}
                    files.append(url)
                }
                for url in files.sorted(by:{$0.path.localizedStandardCompare($1.path) == .orderedAscending}) {add(url)}
            } else {add(root)}
        }
        return result
    }
}

@MainActor final class LibraryStore {
    private struct Saved:Codable {var tracks:[MusicItem]=[];var favorites:[MusicItem]=[]}
    private let defaults:UserDefaults
    private var saved=Saved()
    init(defaults:UserDefaults = .standard) {
        self.defaults=defaults
        if let data=defaults.data(forKey:"library.v1"),let value=try? JSONDecoder().decode(Saved.self,from:data) {saved=value}
    }
    var tracks:[MusicItem] {saved.tracks}
    var favorites:[MusicItem] {saved.favorites}
    func containsFavorite(_ item:MusicItem)->Bool {saved.favorites.contains {$0.id==item.id}}
    @discardableResult func add(_ tracks:[MusicItem])->[MusicItem] {
        var seen=Set(saved.tracks.map(\.id));let added=tracks.filter {seen.insert($0.id).inserted}
        saved.tracks+=added;save();return added
    }
    func favorite(_ item:MusicItem) {
        guard !containsFavorite(item) else {return}
        saved.favorites.append(item);save()
    }
    private func save() {if let data=try? JSONEncoder().encode(saved) {defaults.set(data,forKey:"library.v1")}}
}
