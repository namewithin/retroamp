import AppKit
import AVFoundation
import MediaPlayer

@MainActor extension AppDelegate {
    func checkColdStream(_ path:String) async {
        var result:[String:Any]=[:]
        let original=engine.onError
        engine.onError={message in original?(message);result["engineError"]=message}
        engine.volume(0);engine.mute(true);setVideoVisible(false,persist:false)
        await engine.installSession(nil)
        result["installingSession"]=installingSession
        let item=MusicItem(id:"4D7u5KF7SP8",title:"Cold stream",subtitle:"Muted test",videoID:"4D7u5KF7SP8",browseID:nil,duration:"")
        configureQueue([item],starting:item);let start=ProcessInfo.processInfo.systemUptime;play(item)
        result["requestedID"]=current?.id ?? "none";result["requestedState"]=view.transportState.label;result["requestedStatus"]=view.status
        writeCheck(result,path:path+".progress")
        for _ in 0..<200 {
            if result["engineError"] != nil || (lastState?.hasSource==true && lastState?.ad==false && (lastState?.time ?? 0)>0.5) {break}
            try? await Task.sleep(nanoseconds:200_000_000)
        }
        result["elapsed"]=ProcessInfo.processInfo.systemUptime-start;result["status"]=view.status;result["time"]=lastState?.time ?? 0;result["hasSource"]=lastState?.hasSource ?? false
        result["lastBridgeFailure"]=engine.lastBridgeFailure ?? "none"
        result["ad"]=lastState?.ad ?? false
        result["passed"]=lastState?.hasSource==true && lastState?.ad==false && (lastState?.time ?? 0)>0.5 && result["engineError"]==nil
        writeCheck(result,path:path);NSApp.terminate(nil)
    }

    func checkResourceLifecycle(_ path:String) async {
        var checks:[String:Any]=[:]
        func waitFor(_ predicate:()->Bool) async throws {
            for _ in 0..<100 {if predicate() {return};try await Task.sleep(nanoseconds:100_000_000)}
            throw MusicError.message("Resource lifecycle check timed out")
        }
        func renderPlayer() {guard let b=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {return};view.cacheDisplay(in:view.bounds,to:b)}
        do {
            engine.mute(true);engine.volume(0)
            view.titleLine="Idle";view.artistLine="Ready";view.isPlaying=false;view.spectrumDynamics.reset();view.spectrumInput=Array(repeating:0,count:37)
            window.makeKeyAndOrderFront(nil);renderPlayer();try await Task.sleep(nanoseconds:300_000_000)
            checks["idlePlayerStopsAnimationTimer"]=view.spectrumTimer?.isValid != true
            view.titleLine=String(repeating:"Long title ",count:12);renderPlayer()
            try await waitFor {self.view.spectrumTimer?.isValid==true}
            try await Task.sleep(nanoseconds:1_900_000_000)
            checks["longTitleStillScrollsAfterIdle"]=view.titleMarquee.offset>0
            window.miniaturize(nil);try await Task.sleep(nanoseconds:300_000_000)
            checks["minimizedPlayerStopsAnimation"]=view.spectrumTimer?.isValid != true
            window.deminiaturize(nil);window.makeKeyAndOrderFront(nil);renderPlayer()
            try await waitFor {self.view.spectrumTimer?.isValid==true}
            checks["unminimizeResumesMarquee"]=true
            view.titleLine="Short";view.artistLine="Ready";renderPlayer();try await Task.sleep(nanoseconds:300_000_000)
            checks["shortTitleLetsAnimationSleep"]=view.spectrumTimer?.isValid != true
            mediaControls.clear();let before=mediaControls.publicationCount
            let item=MusicItem(id:"fixture0001",title:"Publication test",subtitle:"",videoID:"fixture0001",browseID:nil,duration:"")
            func state(_ time:Double,_ paused:Bool)->PlaybackState {PlaybackState(time:time,duration:180,paused:paused,ended:false,hasSource:true,ad:false,title:"",artist:"",error:"",volume:0,muted:true)}
            for _ in 0..<100 {mediaControls.update(item:item,state:state(12,true),canNext:true,canPrevious:true)}
            checks["identicalPausedStatePublishesOnce"]=mediaControls.publicationCount==before+1
            mediaControls.update(item:item,state:state(60,true),canNext:true,canPrevious:true)
            checks["seekPublishesImmediately"]=mediaControls.publicationCount==before+2
            mediaControls.update(item:item,state:state(60,false),canNext:true,canPrevious:true)
            checks["resumePublishesImmediately"]=mediaControls.publicationCount==before+3
            mediaControls.clear()
            let url=URL(fileURLWithPath:argument("--resource-local")!),local=MusicItem(id:url.absoluteString,title:"Local lifecycle",subtitle:"Muted fixture",videoID:nil,browseID:nil,duration:"",localURL:url)
            configureQueue([local],starting:local);play(local)
            try await waitFor {(self.lastState?.time ?? 0)>0.6}
            act("pause");let paused=lastState?.time ?? -99;try await Task.sleep(nanoseconds:500_000_000)
            checks["localPausedClockStable"]=lastState?.paused==true && abs((lastState?.time ?? 99)-paused)<0.05
            act("play");try await Task.sleep(nanoseconds:700_000_000)
            checks["localEngineResumesWithoutPositionReset"]=lastState?.paused==false && (lastState?.time ?? 0)>paused+0.4
            act("pause");engine.seek(0.5);let seekTime=lastState?.time ?? 0;act("play");try await Task.sleep(nanoseconds:500_000_000)
            checks["localSeekOnPauseResumesAtSelectedPosition"]=seekTime>80 && (lastState?.time ?? 0)>seekTime+0.25
            act("stop");try await Task.sleep(nanoseconds:300_000_000)
            checks["localStopIsPausedAtZero"]=lastState?.paused==true && (lastState?.time ?? 99)<0.1
            act("play");try await Task.sleep(nanoseconds:400_000_000)
            checks["localStoppedEngineCanRestart"]=lastState?.paused==false && (lastState?.time ?? 0)>0.2 && (lastState?.time ?? 99)<2
            engine.pause()
            repeatMode=0;configureQueue([local],starting:local);refreshMediaCommands()
            checks["lastPausedTrackDisablesSystemNext"] = !MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled
            act("repeat")
            checks["pausedRepeatEnablesSystemNextImmediately"]=lastState?.paused==true && MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled
            act("repeat");act("repeat")
            let imported=MusicItem(id:"imported-lifecycle",title:"Imported",subtitle:"Muted fixture",videoID:nil,browseID:nil,duration:"",localURL:url)
            for background in [false,true] {
                configureQueue([local],starting:local);refreshMediaCommands()
                let disabled = !MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled
                applyImport(LocalImportResult(tracks:[imported]),autoplay:false,navigation:requestGeneration+(background ? 1:0))
                checks[background ? "backgroundImportEnablesPausedSystemNext":"importEnablesPausedSystemNext"]=disabled && MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled && lastState?.paused==true && current?.id==local.id
            }
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent("retroamp-transition-"+UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer {try? FileManager.default.removeItem(at:directory)}
            let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
            var tracks:[MusicItem]=[],lengths:[String:Double]=[:]
            for (i,duration) in [0.35,2.0,4.0].enumerated() {
                let f=directory.appendingPathComponent("track-\(i).wav"),buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(duration*48000))!;buffer.frameLength=buffer.frameCapacity
                buffer.floatChannelData![0].initialize(repeating:0,count:Int(buffer.frameLength))
                try AVAudioFile(forWriting:f,settings:format.settings).write(from:buffer)
                tracks.append(MusicItem(id:f.absoluteString,title:"Transition \(i)",subtitle:"",videoID:nil,browseID:nil,duration:"",localURL:f));lengths[f.absoluteString]=duration
            }
            let receive=engine.onState;var matches=true,opened:[String]=[]
            engine.onState={ [weak self] state in
                if let id=self?.current?.id,let duration=lengths[id],state.hasSource {
                    if abs(state.duration-duration)>0.02 {matches=false}
                    if !state.ended,state.time<0.1,opened.last != id {opened.append(id)}
                }
                receive?(state)
            }
            defer {engine.onState=receive}
            repeatMode=1;configureQueue(Array(tracks.prefix(2)),starting:tracks[0]);play(tracks[0])
            try await waitFor {opened.count>=3}
            checks["naturalTransitionNeverPublishesPreviousFile"]=matches
            checks["repeatQueueAdvancesAndReturnsWithoutSkipping"]=Array(opened.prefix(3))==[tracks[0].id,tracks[1].id,tracks[0].id]
            repeatMode=0;engine.pause()
            if let fixture=argument("--video-fixture") {
                let c=try await engine.prepareVideoFixture(URL(fileURLWithPath:fixture))
                _=try await c.evaluate("(()=>{const Base=window.AudioContext;window.AudioContext=class extends Base{constructor(...args){super(...args);window.fixtureAudioContext=this}};return {}})()")
                let clip=MusicItem(id:"fixture0001",title:"Pause before first signal",subtitle:"",videoID:"fixture0001",browseID:nil,duration:"")
                var states=0;engine.onState={ [weak self] state in states+=1;self?.receive(state) }
                play(clip);engine.pause()
                try await waitFor {self.lastState?.hasSource==true && self.lastState?.paused==true}
                let count=states;try await Task.sleep(nanoseconds:1_200_000_000)
                checks["pauseBeforeFirstSignalUsesSlowPolling"]=states-count<=4 && view.transportState != .failed
                checks["pausedNativeOutputIsSilent"]=self.engine.streamDiagnostics["nativeOutputVolume"]as?Float==0
                engine.resume();try await waitFor {self.lastState?.paused==false}
                checks["nativeTapSurvivesPauseResume"]=self.engine.streamDiagnostics["tapStarted"]as?Bool==true

            }
        } catch {checks["error"]=error.localizedDescription}
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true};writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
