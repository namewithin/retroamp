import AppKit
import AVFoundation

@MainActor extension AppDelegate {
    func checkTransport(_ path:String) async {
        var checks:[String:Any]=[:]
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("retroamp-transport-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        func event(_ code:UInt16,in w:NSWindow?=nil,modifiers:NSEvent.ModifierFlags=[],repeatKey:Bool=false,text:String="z")->NSEvent {
            NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:modifiers,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:(w ?? window).windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:repeatKey,keyCode:code)!
        }
        func button(_ role:String)->MetalButton {view.subviews.compactMap {$0 as? MetalButton}.first {$0.identifier?.rawValue==role}!}
        func bitmap(_ control:NSView)->NSBitmapImageRep? {control.displayIfNeeded();guard let image=control.bitmapImageRepForCachingDisplay(in:control.bounds) else {return nil};control.cacheDisplay(in:control.bounds,to:image);return image}
        func greenPixels(_ control:NSView)->Int {
            guard let image=bitmap(control) else {return 0}
            var count=0
            for x in 0..<image.pixelsWide {for y in 0..<image.pixelsHigh {if let c=image.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),c.greenComponent>0.65,c.greenComponent>c.redComponent+0.15,c.greenComponent>c.blueComponent+0.25 {count+=1}}}
            return count
        }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:960000)!
            buffer.frameLength=960000
            for i in 0..<Int(buffer.frameLength) {buffer.floatChannelData![0][i]=Float(sin(2*Double.pi*440*Double(i)/48000))*0.08}
            var tracks:[MusicItem]=[]
            for name in ["01. First","02. Second","03. Third"] {
                let url=directory.appendingPathComponent(name+".wav");try AVAudioFile(forWriting:url,settings:format.settings).write(from:buffer)
                tracks.append(MusicItem(id:url.absoluteString,title:name,subtitle:"Silent shortcut fixture",videoID:nil,browseID:nil,duration:"",localURL:url))
            }
            window.makeKeyAndOrderFront(nil);window.makeFirstResponder(nil)
            checks["zxbvcMapping"]=[(UInt16(6),"previous"),(7,"play"),(8,"togglePlayback"),(9,"stop"),(11,"next"),(49,"togglePlayback")].allSatisfy {transportKeyAction(event($0.0))==$0.1}
            checks["ukrainianLayoutUsesPhysicalKeys"]=transportKeyAction(event(6,text:"я"))=="previous"
            checks["editingCommandsNotIntercepted"]=transportKeyAction(event(8,modifiers:.command))==nil && transportKeyAction(event(6,modifiers:.option))==nil && transportKeyAction(event(6,repeatKey:true))==nil
            playlistWindow.makeKeyAndOrderFront(nil);playlistWindow.makeFirstResponder(view.query)
            checks["searchTypingNotIntercepted"]=transportKeyAction(event(6,in:playlistWindow))==nil && transportKeyAction(event(49,in:playlistWindow))==nil
            playlistWindow.makeFirstResponder(nil);window.makeKeyAndOrderFront(nil)
            let sheet=NSPanel(contentRect:NSRect(x:0,y:0,width:120,height:60),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false
            window.beginSheet(sheet,completionHandler:nil)
            checks["sheetsNotIntercepted"]=transportKeyAction(event(6))==nil && transportKeyAction(event(6,in:sheet))==nil
            window.endSheet(sheet);sheet.orderOut(nil)
            showSettings();checks["settingsNotIntercepted"]=transportKeyAction(event(6,in:settingsWindow!.window!))==nil;settingsWindow?.window?.orderOut(nil)
            engine.mute(true);configureQueue(tracks,starting:tracks[1]);play(tracks[1])
            try await Task.sleep(nanoseconds:180_000_000)
            checks["playingStateAndLamp"]=view.transportState == .playing && button("play").skinSelected && !button("pause").skinSelected && greenPixels(button("play"))>3
            engine.seek(0.5);act("previous")
            checks["previousRestartsCurrentAfterThreeSeconds"]=current?.id==tracks[1].id && queueIndex==1 && (lastState?.time ?? 100)<0.2
            act("previous")
            checks["secondPreviousSelectsPreviousTrack"]=current?.id==tracks[0].id && queueIndex==0
            configureQueue(tracks,starting:tracks[1]);play(tracks[1]);engine.seek(0.5)
            engine.onState=nil
            act("previous");act("previous")
            checks["doublePreviousWorksBeforeAsyncStateArrives"]=current?.id==tracks[0].id
            engine.onState={ [weak self] state in self?.receive(state) }
            try await Task.sleep(nanoseconds:150_000_000)
            engine.seek(0.5);act("pause")
            checks["pauseStateAndLamp"]=view.transportState == .paused && button("pause").skinSelected && !button("play").skinSelected && greenPixels(button("pause"))>3
            act("previous")
            checks["rewindPreservesPause"]=lastState?.paused==true && (lastState?.time ?? 100)<0.2 && current?.id==tracks[0].id
            act(transportKeyAction(event(8))!)
            checks["cResumesPausedTrack"]=lastState?.paused==false && view.transportState == .playing
            act(transportKeyAction(event(9))!)
            checks["vStopsAndShowsStop"]=lastState?.paused==true && (lastState?.time ?? 100)<0.2 && view.transportState == .stopped && button("stop").skinSelected && !button("pause").skinSelected
            act(transportKeyAction(event(7))!)
            checks["xPlaysStoppedTrack"]=lastState?.paused==false && view.transportState == .playing
            act(transportKeyAction(event(11))!)
            checks["bSelectsNextTrack"]=current?.id==tracks[1].id
            act("stop");act("togglePlayback")
            checks["togglePlaysStoppedTrack"]=view.transportState == .playing
            let original=queue.map(\.id);button("shuffle").performClick(nil)
            checks["shuffleStateAndLamp"]=shuffleEnabled && button("shuffle").skinSelected && greenPixels(button("shuffle"))>3 && queue.first?.id==current?.id
            button("shuffle").performClick(nil)
            checks["shuffleOffRestoresOrder"] = !shuffleEnabled && !button("shuffle").skinSelected && queue.map(\.id)==original
            button("repeat").performClick(nil)
            checks["repeatQueueStateAndLamp"]=repeatMode==1 && button("repeat").skinSelected && greenPixels(button("repeat"))>3
            button("repeat").performClick(nil);checks["repeatOneDistinctLabel"]=repeatMode==2 && button("repeat").title=="REP1"
            button("repeat").performClick(nil);checks["repeatOffLampDark"]=repeatMode==0 && !button("repeat").skinSelected && greenPixels(button("repeat"))==0
            let eq=view.equalizerView
            eq.settings.enabled=false;eq.syncControls();let dark=greenPixels(eq.toggle)
            eq.toggle.performClick(nil);let lit=greenPixels(eq.toggle)
            checks["eqProcessingLampMatchesEnabled"]=eq.settings.enabled && eq.toggle.skinSelected && lit>dark+3
            eq.toggle.performClick(nil);checks["eqProcessingLampOff"] = !eq.settings.enabled && !eq.toggle.skinSelected && greenPixels(eq.toggle)==dark
            eq.toggle.performClick(nil)
            checks["panelVisibilityLamps"]=button("toggleEQ").skinSelected==view.eqVisible && button("togglePlaylist").skinSelected==view.playlistVisible
            engine.pause();view.updateTransport(.paused);saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"transport-pause")
            if let input=argument("--skin-file") {
                activeSkin=try WSZSkin(data:Data(contentsOf:URL(fileURLWithPath:input)),name:"Transport QA");refreshSkin()
                eq.settings.enabled=false;eq.syncControls();let off=bitmap(eq.toggle)?.representation(using:.png,properties:[:])
                eq.toggle.performClick(nil);let on=bitmap(eq.toggle)?.representation(using:.png,properties:[:])
                checks["classicSkinEQStateChangesSprite"]=off != nil && on != nil && off != on
                view.updateTransport(.playing);saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"transport-skin");activeSkin=nil;refreshSkin()
            }
            configureQueue(tracks,starting:tracks[2]);play(tracks[2]);engine.seek(0.995)
            try await Task.sleep(nanoseconds:800_000_000)
            checks["naturalEndShowsStop"]=view.transportState == .stopped
            act("togglePlayback");checks["toggleRestartsAfterNaturalEnd"]=view.transportState == .playing && lastState?.paused==false
            checks["mutedTestPlayback"]=lastState?.muted==true
            engine.pause();view.updateTransport(.paused)
        } catch {checks["error"]=error.localizedDescription}
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true};writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
