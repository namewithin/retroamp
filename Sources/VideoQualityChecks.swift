import AppKit

@MainActor extension AppDelegate {
    func saveVideoScreenshot(_ path:String) throws {
        videoWindow.contentView?.layoutSubtreeIfNeeded()
        guard let content=videoWindow.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds),let _=bitmap.representation(using:.png,properties:[:]) else {throw MusicError.message("No native bitmap")}
        content.cacheDisplay(in:content.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))
    }
    func checkPublicHD(_ path:String) async {
        var result:[String:Any]=[:]
        do {
            engine.volume(0);engine.mute(true);view.volume.value=0
            let item=MusicItem(id:"TUVcZfQe-Kw",title:"Levitating",subtitle:"Dua Lipa",videoID:"TUVcZfQe-Kw",browseID:nil,duration:"")
            configureQueue([item],starting:item);setVideoVisible(true,persist:false);play(item)
            let frame=videoWindow.frame;videoWindow.setFrame(NSRect(x:frame.minX,y:frame.minY,width:800,height:620),display:true)
            for quality in [VideoQuality.hd720,.hd1080] {
                videoPanel.qualityPopup.selectItem(at:VideoQuality.allCases.firstIndex(of:quality)!);videoPanel.changeQuality()
                for _ in 0..<160 {
                    if engine.videoGeometry["height"] as? Int == (quality == .hd720 ? 720:1080),engine.videoOutput.frameCount>3,lastState?.ad==false,let image=videoPanel.canvas.image,Int(image.size.height)==(quality == .hd720 ? 720:1080) {break}
                    try await Task.sleep(nanoseconds:250_000_000)
                }
                if quality == .hd720 {engine.seek(0.04)}
                for _ in 0..<40 {if (lastState?.time ?? 0)>8 {break};try await Task.sleep(nanoseconds:100_000_000)}
                try await Task.sleep(nanoseconds:700_000_000)
                let h=quality == .hd720 ? 720:1080
                result[quality.title]=["source":engine.videoGeometry,"frameWidth":videoPanel.canvas.image?.size.width ?? 0,"frameHeight":videoPanel.canvas.image?.size.height ?? 0,"status":videoPanel.qualityStatus.stringValue,"time":lastState?.time ?? 0]
                result[quality.title+"Decoded"]=engine.videoGeometry["height"] as? Int==h && Int(videoPanel.canvas.image?.size.height ?? 0)==h && lastState?.ad==false
                try saveVideoScreenshot(URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("video-"+quality.title+".png").path)
            }
            act("pause");try await Task.sleep(nanoseconds:500_000_000);let paused=lastState?.time ?? -99
            engine.videoQuality = .hd720;videoPanel.qualityPopup.selectItem(at:1)
            try await Task.sleep(nanoseconds:700_000_000)
            result["pausedQualityState"]=["before":paused,"after":lastState?.time ?? -1,"paused":lastState?.paused ?? false,"geometry":engine.videoGeometry,"imageHeight":videoPanel.canvas.image?.size.height ?? 0,"status":videoPanel.qualityStatus.stringValue]
            result["qualityChangeOnPauseKeepsClock"]=lastState?.paused==true && abs((lastState?.time ?? 99)-paused)<0.2
            act("play")
            for _ in 0..<100 {if engine.videoGeometry["height"] as? Int==720,Int(videoPanel.canvas.image?.size.height ?? 0)==720 {break};try await Task.sleep(nanoseconds:200_000_000)}
            result["resumeUsesRequested720"]=lastState?.paused==false && (lastState?.time ?? 0)>=paused-0.3 && engine.videoGeometry["height"] as? Int==720 && Int(videoPanel.canvas.image?.size.height ?? 0)==720
            result["muted"]=lastState?.muted==true
            result["passed"]=result["720pDecoded"] as? Bool==true && result["1080pDecoded"] as? Bool==true && result["qualityChangeOnPauseKeepsClock"] as? Bool==true && result["resumeUsesRequested720"] as? Bool==true && result["muted"] as? Bool==true
        } catch {result["passed"]=false;result["error"]=error.localizedDescription}
        writeCheck(result,path:path);NSApp.terminate(nil)
    }
    func checkVideoQuality(_ path:String,fixture:URL,audio:URL) async {
        var checks:[String:Any]=[:]
        func waitFor(_ predicate:()->Bool) async throws {
            for _ in 0..<100 {if predicate() {return};try await Task.sleep(nanoseconds:100_000_000)}
            throw MusicError.message("Quality/rendition check timed out: "+checks.keys.sorted().joined(separator:","))
        }
        func row(_ id:String,_ type:String)->[String:Any] {["videoId":id,"navigationEndpoint":["watchEndpoint":["watchEndpointMusicSupportedConfigs":["watchEndpointMusicConfig":["musicVideoType":type]]]]]}
        let source="fixture0001",target="fixture0002"
        let segment:[String:Any]=["primaryVideoStartTimeMilliseconds":"2000","counterpartVideoStartTimeMilliseconds":"0","durationMilliseconds":"12000"]
        let paired:[String:Any]=["counterpartRenderer":["playlistPanelVideoRenderer":row(source,"MUSIC_VIDEO_TYPE_ATV")],"segmentMap":["segment":[segment]]]
        let wrapper:[String:Any]=["primaryRenderer":["playlistPanelVideoRenderer":row(target,"MUSIC_VIDEO_TYPE_OMV")],"counterpart":[paired]]
        let object:[String:Any]=["contents":[["playlistPanelVideoWrapperRenderer":wrapper]]]

        do {
            let parsed=MusicParser.videoRendition(object,for:source)
            checks["explicitPairAndReverseSegmentParsed"]=parsed?.videoID==target && parsed?.segments.first?.from==0 && parsed?.segments.first?.to==2
            checks["unrelatedQueuePairRejected"]=MusicParser.videoRendition(object,for:"fixture0003")==nil
            checks["inverseMapKeepsAudioRecoveryPosition"]=abs((parsed?.originalTime(for:8) ?? -99)-6)<0.001
            checks["videoNotReplacedByAudio"]=MusicParser.videoRendition(object,for:target)==nil
            checks["noPairIsNotGuessed"]=MusicParser.videoRendition(["videoId":target],for:source)==nil
            let unavailable=VideoQualityState(state:["videoGeometry":["width":640,"height":360],"availableQualities":["medium","auto"]],requested:.hd1080)
            checks["unavailableQualityReportsActualResolution"]=unavailable.label.contains("недоступне") && unavailable.label.contains("640×360")
            var authenticated=object;authenticated["responseContext"]=["mainAppWebResponseContext":["loggedOut":false]]
            let cfg=URLSessionConfiguration.ephemeral;cfg.protocolClasses=[LikeFixtureProtocol.self]
            let api=MusicService(config:["INNERTUBE_CONTEXT":["client":["hl":"uk"]]],network:URLSession(configuration:cfg))
            await api.setSession(SessionCredentials(cookie:"SAPISID=synthetic-video-test",authUser:"0",pageID:nil))
            LikeFixtureProtocol.respond(body:String(decoding:try JSONSerialization.data(withJSONObject:authenticated),as:UTF8.self))
            let response=try await api.videoRendition(source),request=LikeFixtureProtocol.lastRequest
            let body=request?.httpBody.flatMap {try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
            checks["authenticatedNextRequestSelectsRequestedPair"]=response?.videoID==target && request?.url?.path=="/youtubei/v1/next" && body?["videoId"] as? String==source && request?.value(forHTTPHeaderField:"Authorization")?.hasPrefix("SAPISIDHASH ")==true
            LikeFixtureProtocol.respond(status:403);var rejected=false;do {_=try await api.videoRendition(source)}catch {rejected=true}
            checks["expiredCounterpartSessionRejected"]=rejected
            engine.volume(0);engine.mute(true);engine.videoQuality = .auto;view.volume.value=0
            let c=try await engine.prepareVideoFixture(fixture)
            let audioSource=MusicEngine.json("data:audio/mp4;base64,"+(try Data(contentsOf:audio)).base64EncodedString())
            _=try await c.evaluate("(()=>{const p=document.querySelector('#movie_player'),v=document.querySelector('video'),video=v.src,audio=\(audioSource);let id='fixture0001';window.fixtureLoads=[];p.getVideoData=()=>({video_id:id});p.getPlayerResponse=()=>({videoDetails:{musicVideoType:id==='fixture0002'?'MUSIC_VIDEO_TYPE_OMV':'MUSIC_VIDEO_TYPE_ATV'}});p.loadVideoById=value=>{id=typeof value==='string'?value:value.videoId;window.fixtureLoads.push(id);v.pause();v.src=id==='fixture0002'?video:audio;const time=typeof value==='string'?0:value.startSeconds||0;v.addEventListener('loadedmetadata',()=>{v.currentTime=time},{once:true})};return {}})()")
            // Observe the real switch result so the ad race is independent of polling cadence.
            _=try await c.evaluate("(()=>{const original=window.__retroamp.switchVideo;window.fixtureSwitches=[];window.__retroamp.switchVideo=function(...args){const result=original.apply(this,args);window.fixtureSwitches.push({ad:document.querySelector('#movie_player').classList.contains('ad-showing'),switched:result.switched===true});return result};return {}})()")
            var lookups=0
            engine.resolveVideoRendition={id in
                lookups+=1
                if lookups==1 {try await Task.sleep(nanoseconds:100_000_000);_=try await c.evaluate("document.querySelector('#movie_player').classList.add('ad-showing');({})")}
                try await Task.sleep(nanoseconds:400_000_000);return MusicParser.videoRendition(object,for:id)
            }
            let first=MusicItem(id:source,title:"Audio with official video",subtitle:"Muted integration fixture",videoID:source,browseID:nil,duration:"")
            setVideoVisible(false,persist:false);configureQueue([first],starting:first);play(first)
            try await waitFor {self.lastState?.hasSource==true && (self.lastState?.time ?? 0)>0.5}
            checks["audioStartsBeforeVideoLookup"]=lookups==0 && engine.videoGeometry["height"] as? Int==0
            act("pause");try await waitFor {self.lastState?.paused==true}
            setVideoVisible(true,persist:false)
            var duringAd:[String:Any]=[:]
            for _ in 0..<100 {
                duringAd=try await c.evaluate("({id:document.querySelector('#movie_player').getVideoData().video_id,attempts:window.fixtureSwitches})")
                if (duringAd["attempts"] as? [[String:Any]])?.isEmpty==false {break}
                try await Task.sleep(nanoseconds:100_000_000)
            }
            let adAttempt=(duringAd["attempts"] as? [[String:Any]])?.first
            checks["lookupDoesNotSwitchDuringAd"]=duringAd["id"] as? String==source && adAttempt?["ad"] as? Bool==true && adAttempt?["switched"] as? Bool==false
            _=try await c.evaluate("document.querySelector('#movie_player').classList.remove('ad-showing');({})")
            engine.seek(0.25)
            try await waitFor {self.engine.videoGeometry["height"] as? Int==1080 && Int(self.videoPanel.canvas.image?.size.height ?? 0)==1080}
            let switched=try await c.evaluate("({id:document.querySelector('#movie_player').getVideoData().video_id,time:document.querySelector('video').currentTime,paused:document.querySelector('video').paused,count:document.querySelectorAll('video,audio').length,loads:window.fixtureLoads})")
            checks["songAutomaticallyGetsOfficialVideo"]=switched["id"] as? String==target && lookups==2
            checks["lookupRetriesAfterAdEnds"]=lookups==2
            checks["switchMapsLatestSeekAndKeepsPause"]=switched["paused"] as? Bool==true && abs((switched["time"] as? Double ?? -99)-5.5)<0.25
            checks["oneMediaElementAndOriginalQueueIdentity"]=switched["count"] as? Int==1 && current?.id==source
            checks["hdFramesNotDownscaled"]=videoPanel.canvas.image?.size.width==1920 && videoPanel.canvas.image?.size.height==1080
            let priorQuality=try await c.evaluate("({request:window.fixtureQuality||null})")
            videoPanel.qualityPopup.selectItem(at:1);videoPanel.changeQuality()
            try await Task.sleep(nanoseconds:250_000_000)
            let quality=try await c.evaluate("({request:window.fixtureQuality,time:document.querySelector('video').currentTime})")
            checks["pausedQualityChoiceDoesNotReloadOrSeek"]=(quality["request"] as? [String])==(priorQuality["request"] as? [String]) && engine.videoQuality == .hd720 && abs((quality["time"] as? Double ?? -99)-5.5)<0.25
            act("play");try await Task.sleep(nanoseconds:300_000_000)
            let applied=try await c.evaluate("({request:window.fixtureQuality,time:document.querySelector('video').currentTime})")
            checks["resumeAppliesQualityWithoutReload"]=(applied["request"] as? [String])==["hd720","hd720"] && (applied["time"] as? Double ?? 0)>5.5
            act("pause");try await waitFor {self.lastState?.paused==true}
            let pausedFrameCount=engine.videoOutput.frameCount
            _=try await c.evaluate("(()=>{const v=document.querySelector('video');Object.defineProperty(v,'videoWidth',{configurable:true,value:1280});Object.defineProperty(v,'videoHeight',{configurable:true,value:720});return {}})()")
            try await waitFor {self.engine.videoOutput.frameCount>pausedFrameCount && Int(self.videoPanel.canvas.image?.size.height ?? 0)==720}
            checks["pausedResolutionChangeRefreshesFrame"]=lastState?.paused==true
            let expectedAudioPosition=(lastState?.time ?? 0)-2
            _=try await c.evaluate("(()=>{const v=document.querySelector('video');delete v.videoWidth;delete v.videoHeight;document.querySelector('#movie_player').classList.add('ad-showing');v.currentTime=.5;return {}})()")
            try await Task.sleep(nanoseconds:500_000_000)
            _=try await c.evaluate("(()=>{const v=document.querySelector('video');const e=document.createElement('div');e.className='ytp-error-content-wrap';e.innerText='Synthetic clip blocked';document.body.append(e);const p=document.querySelector('#movie_player'),load=p.loadVideoById;p.loadVideoById=value=>{p.classList.remove('ad-showing');e.remove();load(value)};return {}})()")
            try await waitFor {self.engine.videoGeometry["height"] as? Int==0 && self.lastState?.hasSource==true}
            checks["clipFailureRestoresAudioAndPause"]=lastState?.paused==true && current?.id==source
            checks["adClockDoesNotReplaceRecordingPosition"]=abs((lastState?.time ?? -99)-expectedAudioPosition)<0.25
            try await Task.sleep(nanoseconds:31_000_000_000)
            checks["pausedAudioRecoverySurvivesStartupDeadline"]=lastState?.paused==true && view.transportState != .failed && abs((lastState?.time ?? -99)-expectedAudioPosition)<0.25
            // A delayed lookup must never replace a newly selected track.
            engine.resolveVideoRendition={id in try? await Task.sleep(nanoseconds:700_000_000);return MusicParser.videoRendition(object,for:id)}
            play(first);try await Task.sleep(nanoseconds:300_000_000)
            let next=MusicItem(id:"fixture0003",title:"No paired clip",subtitle:"",videoID:"fixture0003",browseID:nil,duration:"");play(next)
            try await Task.sleep(nanoseconds:1_200_000_000)
            let final=try await c.evaluate("({id:document.querySelector('#movie_player').getVideoData().video_id,count:document.querySelectorAll('video,audio').length})")
            checks["staleLookupCannotReplaceNextTrack"]=final["id"] as? String==next.id && final["count"] as? Int==1 && current?.id==next.id
            checks["missingClipLeavesAudioPlaying"]=lastState?.hasSource==true && lastState?.paused==false && videoPanel.canvas.message.contains("не надав")
        } catch {checks["error"]=error.localizedDescription}
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true};writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
