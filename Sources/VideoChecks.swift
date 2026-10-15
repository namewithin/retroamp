import AppKit
import AVFoundation
import CryptoKit

@MainActor extension AppDelegate {
    func checkPublicVideo(_ path:String) async {
        var result:[String:Any]=[:]
        do {
            engine.volume(0);engine.mute(true);view.volume.value=0
            let page=try await service.search("Stiff Richards Bad Disease live")
            guard let item=page.items.first(where:{$0.isPlayable && $0.title.lowercased().contains("live")}) else {throw MusicError.message("No public video result")}
            configureQueue([item],starting:item);setVideoVisible(true,persist:false);play(item)
            for _ in 0..<100 {
                if engine.videoOutput.frameCount>=5,lastState?.ad==false {break}
                if view.transportState == .failed {break}
                try await Task.sleep(nanoseconds:300_000_000)
            }
            result["videoID"]=item.videoID;result["frameCount"]=engine.videoOutput.frameCount;result["hasSource"]=lastState?.hasSource==true;result["ad"]=lastState?.ad==true;result["message"]=videoPanel.canvas.message;result["geometry"]=engine.videoGeometry
            let hasFrames=engine.videoOutput.frameCount>=5 && videoPanel.canvas.image != nil && lastState?.ad==false
            act("pause");try await Task.sleep(nanoseconds:350_000_000);let time=lastState?.time ?? -99
            try await Task.sleep(nanoseconds:300_000_000)
            result["pauseSynchronized"]=lastState?.paused==true && abs((lastState?.time ?? 99)-time)<0.15
            let geo=engine.videoGeometry,sourceAspect=(geo["width"] as? Double ?? 0)/max(1,geo["height"] as? Double ?? 0),image=videoPanel.canvas.image
            result["pictureMatchesVideoAspect"]=image != nil && abs((image!.size.width/image!.size.height)-sourceAspect)<0.02
            result["passed"]=hasFrames && result["pauseSynchronized"] as? Bool==true && result["pictureMatchesVideoAspect"] as? Bool==true
            result["speakerOutput"]=false
            if let content=videoWindow.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("video-youtube.png"))}
        } catch {result["passed"]=false;result["error"]=error.localizedDescription}
        writeCheck(result,path:path);NSApp.terminate(nil)
    }
    func checkVideo(_ path:String,fixture:URL) async {
        var checks:[String:Any]=[:]
        func waitFor(_ predicate:()->Bool) async throws {
            for _ in 0..<70 {if predicate() {return};try await Task.sleep(nanoseconds:100_000_000)}
            throw MusicError.message("VIDEO fixture check timed out")
        }
        func digest()->String {guard let bytes=videoPanel.canvas.image?.tiffRepresentation else {return ""};return SHA256.hash(data:bytes).map {String(format:"%02x",$0)}.joined()}
        do {
            engine.volume(0);engine.mute(true);view.volume.value=0
            let c=try await engine.prepareVideoFixture(fixture)
            let first=MusicItem(id:"fixture0001",title:"VIDEO · First fixture",subtitle:"Muted native integration test",videoID:"fixture0001",browseID:nil,duration:"",localURL:nil)
            let second=MusicItem(id:"fixture0002",title:"VIDEO · Second fixture",subtitle:"Same browser, one media element",videoID:"fixture0002",browseID:nil,duration:"",localURL:nil)
            configureQueue([first,second],starting:first);setVideoVisible(true,persist:false);play(first)
            try await waitFor {self.videoPanel.canvas.image != nil && self.engine.videoOutput.frameCount>=5 && (self.lastState?.time ?? 0)>0.4}
            let start=digest();try await Task.sleep(nanoseconds:250_000_000)
            checks["movingFramesFromProductionBrowser"] = !start.isEmpty && start != digest()
            checks["fourthNativeWindow"]=windowGroup.windows.count==4 && videoWindow.isVisible
            let others=[window!,equalizerWindow!,playlistWindow!].map(\.frame),frame=videoWindow.frame
            videoWindow.setFrame(NSRect(x:frame.minX+30,y:frame.minY+20,width:640,height:408),display:true);videoWindow.contentView?.layoutSubtreeIfNeeded()
            checks["videoMovesAndResizesIndependently"]=videoWindow.frame.width==640 && [window!,equalizerWindow!,playlistWindow!].map(\.frame)==others && videoPanel.canvas.frame.width>=620
            act("pause");try await waitFor {self.lastState?.paused==true};let paused=lastState?.time ?? -100
            try await Task.sleep(nanoseconds:300_000_000)
            checks["pauseSharesSameMediaClock"]=abs((lastState?.time ?? 100)-paused)<0.15 && videoPanel.canvas.image != nil
            let pausedCount=engine.videoOutput.frameCount
            setVideoVisible(false,persist:false);setVideoVisible(true,persist:false)
            try await waitFor {self.videoPanel.canvas.image != nil && self.engine.videoOutput.frameCount>pausedCount}
            checks["reopenWhilePausedShowsCurrentFrame"]=lastState?.paused==true && abs((lastState?.time ?? 100)-paused)<0.15
            _=try await c.evaluate("(()=>{const original=window.__retroamp.videoFrame;window.__retroamp.probeOriginal=original;window.frameProbe={active:0,max:0,calls:0};window.__retroamp.videoFrame=key=>{const p=window.frameProbe;p.active++;p.calls++;p.max=Math.max(p.max,p.active);return new Promise(resolve=>setTimeout(()=>{p.active--;resolve(original(key))},300))};return {}})()")
            var probeStarted=false
            for _ in 0..<30 {let value=try await c.evaluate("({active:window.frameProbe.active})");if (value["active"] as? Int ?? 0)>0 {probeStarted=true;break};try await Task.sleep(nanoseconds:20_000_000)}
            for _ in 0..<5 {setVideoVisible(false,persist:false);setVideoVisible(true,persist:false)}
            try await Task.sleep(nanoseconds:800_000_000)
            let probe=try await c.evaluate("({max:window.frameProbe.max,calls:window.frameProbe.calls})")
            checks["delayedFrameProbeRan"]=probeStarted && (probe["calls"] as? Int ?? 0)>=2
            checks["oneInFlightAcrossCaptureRevisions"]=(probe["max"] as? Int ?? 99)==1
            _=try await c.evaluate("window.__retroamp.videoFrame=window.__retroamp.probeOriginal;({})")
            engine.seek(0.65);try await waitFor {abs((self.lastState?.time ?? 0)-(self.lastState?.duration ?? 0)*0.65)<0.2}
            checks["seekWhilePausedStaysSynchronized"]=lastState?.paused==true
            let media=try await c.evaluate("({count:document.querySelectorAll('video,audio').length,time:document.querySelector('video').currentTime,paused:document.querySelector('video').paused})")
            checks["oneMediaElementNoDuplicateAudio"]=media["count"] as? Int==1 && abs((media["time"] as? Double ?? -99)-(lastState?.time ?? 99))<0.2 && media["paused"] as? Bool==true
            act("next");let count=engine.videoOutput.frameCount
            try await waitFor {self.current?.id==second.id && self.engine.videoOutput.frameCount>count+2 && self.videoPanel.canvas.image != nil}
            checks["nextTrackUpdatesVideoAndCaption"]=videoPanel.caption.stringValue.contains(second.title) && (lastState?.time ?? 99)<3
            act("stop");try await waitFor {(self.lastState?.time ?? 99)<0.1 && self.lastState?.paused==true}
            checks["stopResetsSameVideo"]=view.transportState == .stopped
            act("play");try await waitFor {self.lastState?.paused==false && (self.lastState?.time ?? 0)>0.4};setVideoVisible(false,persist:false)
            try await Task.sleep(nanoseconds:250_000_000);let hiddenCount=engine.videoOutput.frameCount,hiddenTime=lastState?.time ?? 0
            let directBefore=try await c.evaluate("({time:document.querySelector('video').currentTime,paused:document.querySelector('video').paused})")
            try await Task.sleep(nanoseconds:300_000_000)
            let directAfter=try await c.evaluate("({time:document.querySelector('video').currentTime,paused:document.querySelector('video').paused})")
            checks["hiddenStateDiagnostic"]=["directBefore":directBefore,"directAfter":directAfter,"windowVisible":videoWindow.isVisible,"capturing":engine.videoOutput.isCapturing,"framesBefore":hiddenCount,"framesAfter":engine.videoOutput.frameCount,"timeBefore":hiddenTime,"timeAfter":lastState?.time ?? -1]
            checks["hiddenVideoStopsCaptureButAudioContinues"] = !videoWindow.isVisible && !engine.videoOutput.isCapturing && engine.videoOutput.frameCount==hiddenCount && (lastState?.time ?? 0)>hiddenTime+0.15
            setVideoVisible(true,persist:false);try await waitFor {self.videoPanel.canvas.image != nil && self.engine.videoOutput.frameCount>hiddenCount}
            checks["reopenVideoResumesCapture"]=current?.id==second.id
            arrangeWindows(nil);let grouped=[window!,equalizerWindow!,playlistWindow!,videoWindow!],before=grouped.map(\.frame)
            windowGroup.beginPlayerDrag();window.setFrameOrigin(NSPoint(x:before[0].minX+25,y:before[0].minY+20));windowGroup.endPlayerDrag()
            checks["dockedVideoMovesWithPlayer"]=zip(grouped,before).allSatisfy {abs($0.0.frame.minX-$0.1.minX-25)<1 && abs($0.0.frame.minY-$0.1.minY-20)<1}
            let detached=videoWindow.frame;videoWindow.setFrameOrigin(NSPoint(x:detached.minX+500,y:detached.minY));let independent=videoWindow.frame
            windowGroup.beginPlayerDrag();window.setFrameOrigin(NSPoint(x:window.frame.minX+25,y:window.frame.minY+20));windowGroup.endPlayerDrag()
            checks["detachedVideoStaysIndependent"]=videoWindow.frame==independent
            windowGroup.setAlwaysOnTop(true,persist:false);checks["videoIncludedInAlwaysOnTop"]=videoWindow.level == .floating;windowGroup.setAlwaysOnTop(false,persist:false)
            videoWindow.makeKeyAndOrderFront(nil);videoWindow.makeFirstResponder(nil)
            let key=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:videoWindow.windowNumber,context:nil,characters:"c",charactersIgnoringModifiers:"c",isARepeat:false,keyCode:8)!
            checks["transportShortcutsWorkInVideoWindow"]=transportKeyAction(key)=="togglePlayback"
            act("pause");try await waitFor {self.lastState?.paused==true}
            let cover=try await c.evaluate("({unchanged:!document.querySelector('style')&&!document.querySelector('video').getAttribute('style')})")
            checks["videoDoesNotAlterSourceLayout"]=cover["unchanged"] as? Bool==true
            arrangeWindows(nil);videoWindow.contentView?.layoutSubtreeIfNeeded()
            if let content=videoWindow.contentView,let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("video-native.png"))}
            _=try await c.evaluate("window.__retroamp.savedVideoFrame=window.__retroamp.videoFrame;window.__retroamp.videoFrame=()=>({error:'Synthetic VIDEO unavailable'});({})")
            act("play");setVideoVisible(false,persist:false);setVideoVisible(true,persist:false)
            try await waitFor {self.engine.videoOutput.lastError != nil && self.lastState?.paused==false}
            let errorTime=lastState?.time ?? 0;try await Task.sleep(nanoseconds:250_000_000)
            checks["videoFailureKeepsAudioRunning"]=videoPanel.canvas.image==nil && !engine.videoOutput.isCapturing && videoPanel.canvas.message=="Synthetic VIDEO unavailable" && (lastState?.time ?? 0)>errorTime+0.1
            _=try await c.evaluate("window.__retroamp.videoFrame=window.__retroamp.savedVideoFrame;({})")
            setVideoVisible(false,persist:false);setVideoVisible(true,persist:false);try await waitFor {self.videoPanel.canvas.image != nil}
            checks["videoCanRecoverAfterFrameFailure"]=engine.videoOutput.lastError==nil
            let url=FileManager.default.temporaryDirectory.appendingPathComponent("retroamp-video-local-"+UUID().uuidString+".wav")
            defer {try? FileManager.default.removeItem(at:url)}
            let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!;buffer.frameLength=48000
            try AVAudioFile(forWriting:url,settings:format.settings).write(from:buffer)
            let local=MusicItem(id:url.absoluteString,title:"Local audio",subtitle:"",videoID:nil,browseID:nil,duration:"",localURL:url);play(local)
            try await Task.sleep(nanoseconds:200_000_000)
            checks["localTrackClearsVideo"]=videoPanel.canvas.image==nil && !engine.videoOutput.isCapturing && videoPanel.canvas.message.contains("YouTube Music")
            checks["mutedPlayback"]=lastState?.muted==true
            engine.pause()
        } catch {checks["error"]=error.localizedDescription+"; frames=\(engine.videoOutput.frameCount), time=\(lastState?.time ?? -1), state=\(view.transportState.label), status=\(view.status), stream=\(engine.streamDiagnostics)";checks["bridgeError"]=(error as?CDPFailure)?.diagnostic ?? "none"}
        checks["passed"]=checks.filter{$0.key != "hiddenStateDiagnostic"}.values.allSatisfy {$0 as? Bool==true};writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
