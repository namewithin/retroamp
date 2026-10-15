import AppKit

@MainActor extension AppDelegate {
    func checkResources(_ path:String) async {
        var result:[String:Any]=["speakerOutput":false,"personalCredentials":false]
        var phases:[[String:Any]]=[]
        let marker=URL(fileURLWithPath:path+".phase.json")
        var stateCount=0,spectrumCount=0,nonzeroSpectrumCount=0
        let originalState=engine.onState,originalSpectrum=engine.onSpectrum
        engine.onState={state in stateCount+=1;originalState?(state)}
        engine.onSpectrum={levels in spectrumCount+=1;if (levels.max() ?? 0)>0.02{nonzeroSpectrumCount+=1};originalSpectrum?(levels)}
        var adWaitSeconds=0.0
        func waitFor(_ predicate:()->Bool) async throws {
            let start=ProcessInfo.processInfo.systemUptime;var previous=start,nonAdWait=0.0
            while ProcessInfo.processInfo.systemUptime-start<180 {
                if view.transportState == .failed {throw MusicError.message(view.status)}
                if predicate() {return}
                let now=ProcessInfo.processInfo.systemUptime,delta=now-previous;previous=now
                if lastState?.ad==true {adWaitSeconds+=delta}else {nonAdWait+=delta}
                if nonAdWait>40 {break}
                try await Task.sleep(nanoseconds:200_000_000)
            }
            throw MusicError.message("Resource scenario not ready; ad=\(lastState?.ad ?? false), time=\(lastState?.time ?? -1), state=\(view.transportState.label), status=\(view.status)")
        }
        func phase(_ name:String) async throws {
            let publications=mediaControls.publicationCount
            let start=ProcessInfo.processInfo.systemUptime,frames=engine.videoOutput.frameCount,states=stateCount,spectra=spectrumCount,signals=nonzeroSpectrumCount
            try JSONSerialization.data(withJSONObject:["phase":name,"pid":ProcessInfo.processInfo.processIdentifier,"started":Date().timeIntervalSince1970,"nativeStream":engine.streamDiagnostics]).write(to:marker,options:.atomic)
            try await Task.sleep(nanoseconds:16_000_000_000)
            let seconds=ProcessInfo.processInfo.systemUptime-start
            phases.append(["name":name,"seconds":seconds,"nowPlayingPublications":mediaControls.publicationCount-publications,"videoFrames":engine.videoOutput.frameCount-frames,"framesPerSecond":Double(engine.videoOutput.frameCount-frames)/seconds,"stateCallbacks":stateCount-states,"spectrumCallbacks":spectrumCount-spectra,"realSpectrumCallbacks":nonzeroSpectrumCount-signals,"nativeStream":engine.streamDiagnostics,"time":lastState?.time ?? 0,"paused":lastState?.paused ?? true,"hasSource":lastState?.hasSource ?? false,"geometry":engine.videoGeometry,"imageWidth":videoPanel.canvas.image?.size.width ?? 0,"imageHeight":videoPanel.canvas.image?.size.height ?? 0])
        }
        do {
            view.visualizerSettings=VisualizerSettings();view.startDisplayTimer();engine.videoQuality = .hd1080;engine.resolveVideoRendition=nil
            engine.volume(0);engine.mute(true);view.volume.value=0;setVideoVisible(false,persist:false)
            if CommandLine.arguments.contains("--resources-video-only") {
                let clip=MusicItem(id:"TUVcZfQe-Kw",title:"Levitating",subtitle:"Dua Lipa",videoID:"TUVcZfQe-Kw",browseID:nil,duration:"")
                configureQueue([clip],starting:clip);setVideoVisible(true,persist:false);play(clip)
                let frame=videoWindow.frame;videoWindow.setFrame(NSRect(x:frame.minX,y:frame.minY,width:800,height:620),display:true)
                try await waitFor{self.engine.videoGeometry["height"]as?Int==1080 && self.engine.videoOutput.frameCount>3 && self.lastState?.ad==false}
                try await phase("youtube_1080_visible")
                act("pause");try await waitFor{self.lastState?.paused==true}
                try await phase("youtube_1080_paused_visible")
            }else{
            try await phase("cold_idle")
            await engine.installSession(nil)
            try await Task.sleep(nanoseconds:4_000_000_000)
            try await phase("connected_idle")
            let audio=MusicItem(id:"4D7u5KF7SP8",title:"Get Lucky",subtitle:"Daft Punk",videoID:"4D7u5KF7SP8",browseID:nil,duration:"")
            configureQueue([audio],starting:audio);play(audio)
            try await waitFor {self.lastState?.hasSource==true && self.lastState?.ad==false && (self.lastState?.time ?? 0)>0.5}
            try await phase("youtube_audio")
            guard (phases.last?["realSpectrumCallbacks"]as?Int ?? 0)>10 else{throw MusicError.message("No real public native PCM signal")}
            act("pause");try await waitFor {self.lastState?.paused==true}
            try await phase("youtube_audio_paused")
            let clip=MusicItem(id:"TUVcZfQe-Kw",title:"Levitating",subtitle:"Dua Lipa",videoID:"TUVcZfQe-Kw",browseID:nil,duration:"")
            configureQueue([clip],starting:clip);setVideoVisible(true,persist:false);play(clip)
            let frame=videoWindow.frame;videoWindow.setFrame(NSRect(x:frame.minX,y:frame.minY,width:800,height:620),display:true)
            try await waitFor {self.engine.videoGeometry["height"] as? Int==1080 && self.engine.videoOutput.frameCount>3 && self.lastState?.ad==false}
            engine.seek(0.04);try await waitFor {(self.lastState?.time ?? 0)>8}
            setVideoVisible(false,persist:false);try await phase("youtube_1080_hidden")
            setVideoVisible(true,persist:false);try await phase("youtube_1080_visible")
            act("pause");try await waitFor {self.lastState?.paused==true}
            try await phase("youtube_1080_paused_visible")
            setVideoVisible(false,persist:false);try await phase("youtube_1080_paused_hidden")
            act("stop");try await phase("youtube_stopped")
            let url=URL(fileURLWithPath:argument("--resource-local")!),local=MusicItem(id:url.absoluteString,title:"Local resource fixture",subtitle:"Muted AAC",videoID:nil,browseID:nil,duration:"",localURL:url)
            configureQueue([local],starting:local);play(local);try await waitFor {self.engine.isLocal && self.lastState?.hasSource==true}
            try await phase("local_audio")
            act("pause");try await phase("local_paused")
            }
            result["passed"]=true
        } catch {result["passed"]=false;result["error"]=error.localizedDescription;result["status"]=view.status;result["transport"]=view.transportState.label;result["currentID"]=current?.id ?? "none"}
        result["lastBridgeFailure"]=engine.lastBridgeFailure ?? "none";result["readinessAdWaitSeconds"]=adWaitSeconds;result["phases"]=phases;try? JSONSerialization.data(withJSONObject:["phase":"done","pid":ProcessInfo.processInfo.processIdentifier]).write(to:marker,options:.atomic)
        writeCheck(result,path:path);NSApp.terminate(nil)
    }
}
