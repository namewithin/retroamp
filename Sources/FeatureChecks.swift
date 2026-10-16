import AppKit
import AVFoundation
import MediaPlayer

final class LikeFixtureProtocol:URLProtocol {
    private static let lock=NSLock()
    private static var recorded:URLRequest?
    private static var responseStatus=200
    private static var responseData=Data(#"{"status":"STATUS_SUCCEEDED","responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.utf8)
    static func respond(status:Int=200,body:String = #"{"status":"STATUS_SUCCEEDED","responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#) {lock.lock();defer {lock.unlock()};responseStatus=status;responseData=Data(body.utf8)}
    static var lastRequest:URLRequest? {lock.lock();defer {lock.unlock()};return recorded}
    override class func canInit(with request:URLRequest)->Bool {request.url?.host=="music.youtube.com"}
    override class func canonicalRequest(for request:URLRequest)->URLRequest {request}
    override func startLoading() {
        var record=request
        if record.httpBody==nil,let stream=record.httpBodyStream {
            stream.open();defer {stream.close()};var data=Data(),bytes=[UInt8](repeating:0,count:1024)
            while stream.hasBytesAvailable {let n=stream.read(&bytes,maxLength:bytes.count);if n<=0 {break};data.append(contentsOf:bytes.prefix(n))};record.httpBody=data
        }
        Self.lock.lock();Self.recorded=record;let code=Self.responseStatus,data=Self.responseData;Self.lock.unlock()
        let response=HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed);client?.urlProtocol(self,didLoad:data);client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor extension AppDelegate {
    func checkV09(_ path:String) async {
        var checks:[String:Any]=[:]
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("retroamp-features-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        do {
            let album=directory.appendingPathComponent("Album"),disc=album.appendingPathComponent("Disc 2"),empty=directory.appendingPathComponent("Empty")
            for url in [disc,empty] {try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true)}
            let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:240000)!
            buffer.frameLength=240000
            for i in 0..<Int(buffer.frameLength) {buffer.floatChannelData![0][i]=Float(sin(2*Double.pi*1000*Double(i)/48000))*0.1}
            let files=[album.appendingPathComponent("2. Second.wav"),album.appendingPathComponent("10. Tenth.wav"),disc.appendingPathComponent("1. Nested.wav")]
            for url in files {try AVAudioFile(forWriting:url,settings:format.settings).write(from:buffer)}
            try Data("cover".utf8).write(to:album.appendingPathComponent("cover.jpg"))
            try FileManager.default.createSymbolicLink(at:disc.appendingPathComponent("cycle"),withDestinationURL:album)
            let result=LocalImporter.collect([album,files[0]])
            checks["nestedAlbumImportAndDuplicateRoots"]=result.tracks.count==3 && Set(result.tracks.compactMap(\.localURL))==Set(files)
            checks["naturalTrackOrder"]=result.tracks.prefix(2).map(\.title)==["2. Second","10. Tenth"]
            checks["emptyFolderHasNoTracks"]=LocalImporter.collect([empty]).tracks.isEmpty
            checks["missingFolderReportsError"]=LocalImporter.collect([directory.appendingPathComponent("missing")]).unreadable.count==1
            importFiles([album],autoplay:false);await importTask?.value
            checks["importedTracksVisibleInPlayer"]=items.count==3 && view.table.numberOfRows==3 && items.allSatisfy(\.isPlayable)
            importFiles([album],autoplay:false);await importTask?.value
            checks["repeatImportDoesNotDuplicateQueue"]=queue.count==3
            let restored=LibraryStore()
            checks["localLibrarySurvivesRelaunch"]=restored.tracks.count==3 && Set(restored.tracks.map(\.id))==Set(result.tracks.map(\.id))
            importFiles([empty],autoplay:true);await importTask?.value
            checks["emptyFolderDoesNotStartSavedTrack"]=current==nil && queue.count==3 && items.count==3
            importFiles([directory.appendingPathComponent("missing")],autoplay:true);await importTask?.value
            checks["missingFolderDoesNotStartSavedTrack"]=current==nil && queue.count==3 && items.count==3
            importTask=Task {try? await Task.sleep(nanoseconds:50_000_000)}
            importFiles([album],autoplay:true);showFavorites();await importTask?.value
            checks["asyncImportPreservesNewerNavigation"]=view.sectionTitle=="FAVORITES" && items.isEmpty && current==nil && library.tracks.count==3
            showLocalLibrary();checks["localLibraryMenuShowsAllTracks"]=items.count==3 && view.sectionTitle=="LOCAL FILES"
            engine.mute(true);queue=items;queueIndex=0;play(items[0])
            try await Task.sleep(nanoseconds:300_000_000)
            view.playlistButtons.last?.performClick(nil)
            checks["plusFavoritesCurrentTrack"]=library.favorites.count==1 && library.favorites.first?.id==current?.id
            view.playlistButtons.last?.performClick(nil)
            checks["favoriteIsIdempotentAndPersistent"]=library.favorites.count==1 && LibraryStore().favorites.count==1
            showFavorites();checks["favoritesVisible"]=items.count==1 && items[0].id==current?.id
            checks["systemNowPlayingRegistered"]=mediaControls.active && MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyTitle] as? String==current?.title
            checks["remotePauseAccepted"]=mediaControls.handle(.pause) == .success
            try await Task.sleep(nanoseconds:150_000_000)
            checks["remotePauseStopsLocalPlayback"]=lastState?.paused==true
            checks["remoteToggleAccepted"]=mediaControls.handle(.toggle) == .success
            try await Task.sleep(nanoseconds:150_000_000)
            checks["remoteToggleResumesLocalPlayback"]=lastState?.paused==false
            checks["remoteSeekAccepted"]=mediaControls.handle(.seek(2)) == .success
            try await Task.sleep(nanoseconds:150_000_000)
            checks["remoteSeekChangesPosition"]=(lastState?.time ?? 0)>1.9 && (lastState?.time ?? 0)<2.5
            checks["remoteNextAccepted"]=mediaControls.handle(.next) == .success
            try await Task.sleep(nanoseconds:150_000_000)
            checks["remoteNextSelectsNextTrack"]=current?.id==queue[1].id
            checks["remotePreviousAccepted"]=mediaControls.handle(.previous) == .success
            checks["remotePreviousSelectsPreviousTrack"]=current?.id==queue[0].id
            checks["allPlaybackChecksMuted"]=lastState?.muted==true
            engine.pause();mediaControls.clear()
            checks["remoteCommandsRejectNoSource"]=mediaControls.handle(.toggle) == .noSuchContent
            let cfg=URLSessionConfiguration.ephemeral;cfg.protocolClasses=[LikeFixtureProtocol.self]
            let service=MusicService(config:["INNERTUBE_CONTEXT":["client":["hl":"uk"]]],network:URLSession(configuration:cfg))
            await service.setSession(SessionCredentials(cookie:"SAPISID=fixture",authUser:"0",pageID:nil))
            try await service.like("4D7u5KF7SP8")
            let req=LikeFixtureProtocol.lastRequest
            let body=req?.httpBody.flatMap {try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
            checks["youtubeLikeUsesAuthenticatedEndpoint"]=req?.url?.path=="/youtubei/v1/like/like" && req?.httpMethod=="POST" && (body?["target"] as? [String:String])?["videoId"]=="4D7u5KF7SP8" && req?.value(forHTTPHeaderField:"Authorization")?.hasPrefix("SAPISIDHASH ")==true
            LikeFixtureProtocol.respond(status:403)
            var rejected=false;do {try await service.like("4D7u5KF7SP8")} catch {rejected=true}
            checks["youtubeLikeRejectsExpiredSession"]=rejected
            LikeFixtureProtocol.respond(body:#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#)
            rejected=false;do {try await service.like("4D7u5KF7SP8")} catch {rejected=true}
            checks["youtubeLikeRequiresSuccessConfirmation"]=rejected
            LikeFixtureProtocol.respond(body:#"{"status":1,"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#)
            rejected=false;do {try await service.like("4D7u5KF7SP8")} catch {rejected=true}
            checks["youtubeLikeRejectsMalformedConfirmation"]=rejected
            LikeFixtureProtocol.respond()
            await service.setSession(nil);rejected=false;do {try await service.like("4D7u5KF7SP8")} catch {rejected=true}
            checks["youtubeLikeRequiresSignIn"]=rejected
            let s=VisualizerSettings(),d=SpectrumDynamics()
            let high=Float((-18.0+90)/90),low=Float((-48.0+90)/90)
            for _ in 0..<10 {d.step(input:Array(repeating:high,count:37),playing:true,delta:1/24,settings:s)}
            let height=d.levels[0]
            for _ in 0..<8 {d.step(input:Array(repeating:low,count:37),playing:true,delta:1/24,settings:s)}
            checks["spectrumFallsAfterTransient"]=height-d.levels[0]>0.35 && height<0.95
            var sensitive=s;sensitive.sensitivity=8
            checks["sensitivityChangesOnlyVisualScale"]=sensitive.level(low)>s.level(low)+0.2
            for _ in 0..<24 {d.step(input:Array(repeating:high,count:37),playing:false,delta:1/24,settings:s)}
            checks["pausedSpectrumDecays"]=d.levels.allSatisfy {$0<0.001}
            let samples=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:2048)!;samples.frameLength=2048
            for i in 0..<2048 {samples.floatChannelData![0][i]=Float(sin(2*Double.pi*1000*Double(i)/48000))*0.2}
            let bins=SpectrumAnalyser().analyse(samples) ?? []
            let rendered=bins.map(s.level)
            checks["toneHasFrequencyContrast"]=rendered.count==37 && (rendered.max() ?? 0)>0.4 && rendered.filter {$0>0.9}.count<4 && rendered.filter {$0<0.1}.count>20
            checks["equalizerAndFFT"]=try checkEqualizerAudio()["passed"] as? Bool==true
            arrangeWindows(nil)
            let initial=[window!,equalizerWindow!,playlistWindow!].map(\.frame)
            windowGroup.beginPlayerDrag();window.setFrameOrigin(NSPoint(x:initial[0].minX+30,y:initial[0].minY-20));windowGroup.endPlayerDrag()
            checks["transitiveDockedGroupMovesTogether"]=zip([window!,equalizerWindow!,playlistWindow!],initial).allSatisfy {$0.frame.origin==NSPoint(x:$1.minX+30,y:$1.minY-20)}
            playlistWindow.setFrameOrigin(NSPoint(x:window.frame.maxX+150,y:window.frame.minY))
            let detached=playlistWindow.frame,eqOrigin=equalizerWindow.frame.origin,mainOrigin=window.frame.origin
            windowGroup.beginPlayerDrag();window.setFrameOrigin(NSPoint(x:mainOrigin.x+20,y:mainOrigin.y+10));windowGroup.endPlayerDrag()
            checks["detachedPanelStaysIndependent"]=playlistWindow.frame==detached && equalizerWindow.frame.origin==NSPoint(x:eqOrigin.x+20,y:eqOrigin.y+10)
            showSettings();checks["settingsWindowAvailable"]=settingsWindow?.window?.isVisible==true
            settingsWindow?.window?.orderOut(nil)
            view.spectrum=rendered;view.peaks=rendered;view.titleLine="FEATURE CHECK · LOCAL ALBUM";view.artistLine="Muted verification";saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"v09")
        } catch {checks["error"]=error.localizedDescription}
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true}
        writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
