import AppKit
import UniformTypeIdentifiers

@MainActor extension AppDelegate {
    @objc func focusPlayer() {window.deminiaturize(nil);windowGroup.bringForward(window)}
    @objc func focusEqualizer() {view.eqVisible=true;view.arrangeModules();windowGroup.bringForward(equalizerWindow)}
    @objc func focusPlaylist() {view.playlistVisible=true;view.arrangeModules();windowGroup.bringForward(playlistWindow)}
    @objc func openLocalFolder() {chooseLocalFiles(foldersOnly:true)}
    func chooseLocalFiles(foldersOnly:Bool) {
        guard window.attachedSheet==nil,!installingSession else {return}
        let panel=NSOpenPanel();panel.allowedContentTypes=foldersOnly ? [.folder] : [.audio,.folder]
        panel.canChooseDirectories=true;panel.canChooseFiles = !foldersOnly;panel.allowsMultipleSelection=true
        panel.prompt="Додати";panel.title=foldersOnly ? "Додати папки з альбомами" : "Додати аудіофайли або папки"
        panel.beginSheetModal(for:window) {[weak self] response in
            if response == .OK {let urls=panel.urls;DispatchQueue.main.async {self?.importFiles(urls,autoplay:false)}}
        }
    }
    func applyImport(_ result:LocalImportResult,autoplay:Bool,navigation:Int) {
        let isCurrent=navigation==requestGeneration
        guard !result.tracks.isEmpty else {
            if isCurrent {status(result.unreadable.isEmpty ? "У ПАПЦІ НЕМАЄ ПІДТРИМУВАНИХ АУДІОФАЙЛІВ" : "НЕ ВДАЛОСЯ ПРОЧИТАТИ ПАПКУ. ПЕРЕВІРТЕ ДОСТУП.")}
            return
        }
        let added=library.add(result.tracks)
        var seen=Set(queue.map(\.id));queue+=result.tracks.filter {seen.insert($0.id).inserted}
        refreshMediaCommands()
        guard isCurrent else {return}
        setPage(MusicPage(items:queue,continuation:nil),title:"PLAYLIST EDITOR",endpoint:"local")
        status("ДОДАНО \(added.count) • У ЧЕРЗІ \(queue.count)"+(result.unreadable.isEmpty ? "" : " • НЕ ПРОЧИТАНО: \(result.unreadable.count)"))
        if autoplay,current==nil,let first=result.tracks.first {queueIndex=queue.firstIndex(where:{$0.id==first.id}) ?? 0;play(first)}
    }
    @objc func showLocalLibrary() {
        requestGeneration+=1;requestTask?.cancel()
        setPage(MusicPage(items:library.tracks,continuation:nil),title:"LOCAL FILES",endpoint:"local")
        status("\(items.count) ЛОКАЛЬНИХ ФАЙЛІВ • ПОДВІЙНИЙ КЛІК ДЛЯ ВІДТВОРЕННЯ")
    }
    @objc func showFavorites() {
        requestGeneration+=1;requestTask?.cancel()
        setPage(MusicPage(items:library.favorites,continuation:nil),title:"FAVORITES",endpoint:"favorites")
        status("\(items.count) УЛЮБЛЕНИХ • + ДОДАЄ ПОТОЧНИЙ ТРЕК")
    }
    @objc func loadMore() {act("more")}
    @objc func showSettings() {
        if settingsWindow==nil {
            let controller=SettingsWindow(settings:view.visualizerSettings)
            controller.onChange={ [weak self] settings in self?.view.applyVisualizer(settings) }
            settingsWindow=controller
        }
        settingsWindow?.showWindow(nil);settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }
    func updateFavoriteButton() {
        guard let button=view.playlistButtons.last else {return}
        let saved=current.map {library.containsFavorite($0)} ?? false
        button.title=saved ? "✓" : "+";button.isEnabled=current != nil && favoriteTask==nil;button.needsDisplay=true
        button.setAccessibilityLabel(saved ? "Поточний трек в улюблених" : "Додати поточний трек до улюблених")
    }
    func addCurrentFavorite() {
        guard let item=current,favoriteTask==nil else {status("СПОЧАТКУ ВІДКРИЙТЕ ТРЕК");return}
        if let id=item.videoID {
            guard credentials != nil else {status("ДЛЯ УЛЮБЛЕНИХ YOUTUBE MUSIC УВІЙДІТЬ ЧЕРЕЗ GOOGLE");showConnection();return}
            let session=sessionGeneration
            status("ДОДАЮ ДО УЛЮБЛЕНИХ YOUTUBE MUSIC…")
            favoriteTask=Task { @MainActor [weak self] in
                guard let self else {return}
                defer {self.favoriteTask=nil;self.updateFavoriteButton()}
                do {
                    try await self.service.like(id)
                    guard !Task.isCancelled,session==self.sessionGeneration else {return}
                    self.library.favorite(item)
                    self.status("ДОДАНО ДО УЛЮБЛЕНИХ YOUTUBE MUSIC")
                } catch {if !Task.isCancelled,session==self.sessionGeneration {self.status(error.localizedDescription)}}
            };updateFavoriteButton()
        } else {
            library.favorite(item);updateFavoriteButton();status("ДОДАНО ДО УЛЮБЛЕНИХ RETROAMP")
        }
    }
    func handleMediaAction(_ action:MediaControls.Action)->Bool {
        guard current != nil,!installingSession,lastState?.hasSource==true else {return false}
        switch action {
        case .play:act("play")
        case .pause:act("pause")
        case .toggle:act("togglePlayback")
        case .stop:act("stop")
        case .next:guard queueIndex+1<queue.count || repeatMode==1 else {return false};act("next")
        case .previous:act("previous")
        case .seek(let seconds):guard let state=lastState,state.duration>0,!state.ad,seconds.isFinite else {return false};previousRewind=nil;engine.seek(min(1,max(0,seconds/state.duration)))
        }
        return true
    }
}
