import AppKit

@MainActor extension AppDelegate {
    func checkWindows(_ path:String) {
        let windows=[window!,equalizerWindow!,playlistWindow!],before=windows.map(\.frame)
        var checks:[String:Any]=[:]
        checks["applicationActiveDuringCheck"] = NSApp.isActive
        checks["threeIndependentWindows"]=Set(windows.map {ObjectIdentifier($0)}).count==3 && windows.allSatisfy(\.isVisible)
        for (i,w) in windows.enumerated() {
            var f=w.frame;f.origin.x+=35;f.origin.y+=25;f.size.width+=80;f.size.height+=40;w.setFrame(f,display:true);w.contentView?.layoutSubtreeIfNeeded()
            checks["window\(i)MoveResize"]=w.frame==f && windows.enumerated().filter {$0.offset != i}.allSatisfy {$0.element.frame==before[$0.offset]}
            w.setFrame(before[i],display:true);w.contentView?.layoutSubtreeIfNeeded()
        }
        let initialRows=view.scroll.frame.height
        var f=playlistWindow.frame;f.size.height+=140;playlistWindow.setFrame(f,display:true);playlistWindow.contentView?.layoutSubtreeIfNeeded()
        checks["playlistResizeAddsRows"]=view.scroll.frame.height>=initialRows+130
        view.eqVisible=false;view.arrangeModules();checks["eqHideKeepsOthers"] = !equalizerWindow.isVisible && window.isVisible && playlistWindow.isVisible
        view.eqVisible=true;view.arrangeModules();checks["revealedEQReceivesFocus"] = equalizerWindow.isKeyWindow;view.playlistVisible=false;view.arrangeModules();checks["playlistHideKeepsOthers"] = !playlistWindow.isVisible && window.isVisible && equalizerWindow.isVisible
        view.playlistVisible=true;view.arrangeModules();checks["revealedPlaylistReceivesFocus"] = playlistWindow.isKeyWindow
        for w in windows {w.contentView?.layoutSubtreeIfNeeded();w.contentView?.displayIfNeeded()}
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true}
        writeCheck(checks,path:path);saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"default")
        NSApp.terminate(nil)
    }
    func checkSkin(_ path:String,input:String) {
        var checks:[String:Any]=[:]
        do {
            let data=try Data(contentsOf:URL(fileURLWithPath:input))
            let skin=try WSZSkin(data:data,name:"QA skin");activeSkin=skin;refreshSkin();checks["validWSZLoaded"]=true
            var rejected=false;do {_=try WSZSkin(data:Data(data.prefix(50)),name:"Invalid")} catch {rejected=true};checks["truncatedArchiveRejected"]=rejected
            var nonzip=false;do {_=try WSZSkin(data:Data(repeating:0,count:100),name:"Invalid")} catch {nonzip=true};checks["nonZIPRejected"]=nonzip
            let controls=view.subviews.compactMap {$0 as? MetalButton};checks["transportSkinCoordinates"]=controls.first(where:{$0.identifier?.rawValue=="play"})?.frame==view.skinRect(NSRect(x:39,y:88,width:23,height:18))
            checks["eqSkinCoordinates"]=view.equalizerView.sliders[1].frame==view.equalizerView.scaled(NSRect(x:78,y:38,width:14,height:63))
            view.clock="01:23";view.titleLine="SKIN TEST";view.artistLine="Local / YouTube Music";view.spectrum=(0..<37).map {Float($0%9)/9};view.needsDisplay=true
            saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"skin")
            activeSkin=nil;refreshSkin();checks["defaultRestored"]=controls.first(where:{$0.identifier?.rawValue=="play"})?.frame==view.defaultFrames["play"]
        } catch {checks["error"]=error.localizedDescription}
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true};writeCheck(checks,path:path);NSApp.terminate(nil)
    }
    func writeCheck(_ value:[String:Any],path:String) {if let data=try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path))}}
    func saveModuleRenders(_ directory:URL,prefix:String) {
        for (key,w) in [("main",window!), ("equalizer",equalizerWindow!), ("playlist",playlistWindow!)] {
            guard let content=w.contentView else {continue};content.layoutSubtreeIfNeeded();content.displayIfNeeded()
            if let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {content.cacheDisplay(in:content.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:directory.appendingPathComponent(prefix+"-"+key+".png"))}
        }
    }
}

@MainActor extension AppDelegate {
    func checkDisplay(_ path:String) {
        if let input=argument("--skin-file") {
            do {activeSkin=try WSZSkin(data:Data(contentsOf:URL(fileURLWithPath:input)),name:"Display QA");refreshSkin()}
            catch {writeCheck(["passed":false,"error":error.localizedDescription],path:path);NSApp.terminate(nil);return}
        }
        let oldRemaining=view.remainingTime,oldWide=view.wideSpectrum
        let oldTitle=view.titleLine,oldArtist=view.artistLine
        var checks:[String:Any]=[:]
        view.remainingTime=false;view.updateClock(time:83,duration:270)
        checks["elapsedClock"] = view.clock=="01:23"
        view.clockControl.performClick(nil)
        checks["remainingClick"] = view.clock=="−03:07"
        view.updateClock(time:125,duration:270)
        checks["remainingUpdates"] = view.clock=="−02:25"
        view.clockControl.performClick(nil)
        checks["elapsedClickReturns"] = view.clock=="02:05"
        view.remainingTime=true;view.updateClock(time:500,duration:270)
        checks["remainingClampsAtEnd"] = view.clock=="−00:00"
        view.updateClock(time:.nan,duration:.infinity)
        checks["unknownDurationIsFinite"] = view.clock=="−00:00"
        view.wideSpectrum=false;view.spectrum=Array(repeating:0,count:37);view.peaks=Array(repeating:0,count:37);view.spectrum[36]=0.8;view.peaks[36]=0.9
        checks["fineSpectrum37Columns"] = view.spectrumColumns().count==37
        view.spectrumControl.performClick(nil)
        checks["wideClick19ColumnsPreservesHighFrequency"] = view.spectrumColumns().count==19 && view.spectrumColumns().last?.level==0.8 && view.spectrumColumns().last?.peak==0.9
        view.spectrumControl.performClick(nil)
        checks["fineClickReturns"] = view.spectrumColumns().count==37
        checks["searchAndRowsUseSameTypeface"] = view.query.font?.familyName==drawingFont(size:10,bold:false)?.familyName
        checks["mainFooterRemoved"] = view.statusLabel.superview===view.playlistView && view.bounds.height==146
        let baseTitle="A very long song title that does not fit in this compact player — test scrolling all the way around"
        view.titleLine=baseTitle;view.artistLine="Long artist name also scrolls in the player";view.updateClock(time:83,duration:270);view.remainingTime=false;view.updateClock(time:83,duration:270)
        arrangeWindows(nil);saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"display-before")
        let marquee=activeSkin==nil ? view.titleMarquee : view.skinMarquee
        marquee.advance(2);marquee.advance(1)
        view.artistMarquee.advance(2);view.artistMarquee.advance(1)
        let offset=marquee.offset
        checks["longTitleScrolls"] = offset>0
        view.titleLine=baseTitle
        checks["sameStateDoesNotResetScroll"] = marquee.offset==offset
        saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"display-scrolled")
        engine.mute(true)
        checks["marqueeWasMovingBeforeSameTextTrackChange"] = marquee.offset>0
        let duplicate=MusicItem(id:"marquee-other-track",title:baseTitle,subtitle:view.artistLine,videoID:nil,browseID:nil,duration:"",localURL:URL(fileURLWithPath:"/private/tmp/retroamp-marquee-missing-fixture.wav"))
        play(duplicate)
        checks["differentTrackSameTextResetsBothLines"] = view.titleMarquee.offset==0 && view.artistMarquee.offset==0 && view.skinMarquee.offset==0
        view.titleLine="Short"
        checks["newSongResetsScroll"] = marquee.offset==0
        view.artistLine="Artist"
        saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"display-short")
        marquee.advance(2);marquee.advance(1)
        checks["shortTitleStaysStill"] = marquee.offset==0
        view.remainingTime=true;view.updateClock(time:83,duration:270);view.wideSpectrum=true
        view.spectrum=(0..<37).map {Float($0%9)/9};view.peaks=view.spectrum
        view.titleLine=baseTitle
        saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"display-wide")
        view.remainingTime=oldRemaining;view.wideSpectrum=oldWide
        UserDefaults.standard.set(oldRemaining,forKey:"display.remainingTime");UserDefaults.standard.set(oldWide,forKey:"display.wideSpectrum")
        view.titleLine=oldTitle;view.artistLine=oldArtist;view.updateClock(time:0,duration:0)
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true};writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}

@MainActor extension AppDelegate {
    func checkWindowGroup(_ path:String) {
        let windows=[window!,equalizerWindow!,playlistWindow!],original=windows.map(\.frame),oldPin=windowGroup.alwaysOnTop
        var checks:[String:Any]=[:]
        checks["activeApplication"] = NSApp.isActive
        windowGroup.beginPlayerDrag();window.setFrameOrigin(NSPoint(x:original[0].minX+47,y:original[0].minY-29));windowGroup.endPlayerDrag()
        checks["playerDragMovesAllThreeBySameDelta"] = zip(windows,original).allSatisfy {w,f in abs(w.frame.minX-f.minX-47)<0.01 && abs(w.frame.minY-f.minY+29)<0.01 && w.frame.size==f.size}
        let grouped=windows.map(\.frame)
        equalizerWindow.setFrameOrigin(NSPoint(x:grouped[1].minX+23,y:grouped[1].minY+11))
        checks["eqCanMoveIndependently"] = window.frame==grouped[0] && playlistWindow.frame==grouped[2]
        let afterEQ=windows.map(\.frame)
        playlistWindow.setFrameOrigin(NSPoint(x:afterEQ[2].minX-31,y:afterEQ[2].minY+14))
        checks["playlistCanMoveIndependently"] = window.frame==afterEQ[0] && equalizerWindow.frame==afterEQ[1]
        let beforeResize=windows.map(\.frame);var frame=window.frame;frame.size.height+=32;frame.origin.y-=32;window.setFrame(frame,display:true)
        checks["mainResizeDoesNotMoveCompanions"] = equalizerWindow.frame==beforeResize[1] && playlistWindow.frame==beforeResize[2]
        playlistWindow.orderOut(nil);let hiddenFrame=playlistWindow.frame,mainFrame=window.frame
        windowGroup.beginPlayerDrag();window.setFrameOrigin(NSPoint(x:mainFrame.minX+19,y:mainFrame.minY+9));windowGroup.endPlayerDrag()
        checks["hiddenPanelFollowsWithoutBeingShown"] = !playlistWindow.isVisible && playlistWindow.frame.origin==NSPoint(x:hiddenFrame.minX+19,y:hiddenFrame.minY+9)
        playlistWindow.makeKeyAndOrderFront(nil)
        let obstruction=NSWindow(contentRect:NSRect(x:50,y:50,width:70,height:50),styleMask:[.titled],backing:.buffered,defer:false);obstruction.isReleasedWhenClosed=false;obstruction.title="Group ordering fixture"
        var spectrumPixelCounts:[String:Int]=[:]
        var raises=true
        for selected in windows {
            obstruction.makeKeyAndOrderFront(nil);windowGroup.bringForward(selected)
            let ordered=NSApp.orderedWindows
            guard let cover=ordered.firstIndex(where:{$0===obstruction}) else {raises=false;continue}
            raises = raises && windows.allSatisfy {w in ordered.firstIndex(where:{$0===w}).map {$0<cover} ?? false} && selected.isKeyWindow
        }
        checks["eachSelectedPanelRaisesWholeGroupAboveCover"] = raises
        obstruction.orderOut(nil)
        let sheet=NSPanel(contentRect:NSRect(x:0,y:0,width:180,height:80),styleMask:[.titled],backing:.buffered,defer:false);sheet.isReleasedWhenClosed=false
        window.beginSheet(sheet)
        windowGroup.bringForward(playlistWindow)
        checks["otherPanelSheetDoesNotStealKeyboardFocus"] = playlistWindow.isKeyWindow && !sheet.isKeyWindow && window.attachedSheet===sheet
        windowGroup.bringForward(window)
        checks["selectedParentActivatesItsOwnSheet"] = sheet.isKeyWindow
        window.endSheet(sheet);sheet.orderOut(nil)
        windowGroup.setAlwaysOnTop(false,persist:false)
        let pin=view.subviews.compactMap {$0 as? MetalButton}.first {$0.identifier?.rawValue=="pin"}
        pin?.performClick(nil)
        checks["pinButtonMakesAllWindowsFloating"] = windowGroup.alwaysOnTop && windows.allSatisfy {$0.level == .floating} && pin?.skinSelected==true
        pin?.performClick(nil)
        checks["pinButtonReturnsAllWindowsToNormal"] = !windowGroup.alwaysOnTop && windows.allSatisfy {$0.level == .normal} && pin?.skinSelected==false
        playlistWindow.orderOut(nil);windowGroup.setAlwaysOnTop(true,persist:false);playlistWindow.makeKeyAndOrderFront(nil)
        checks["hiddenPanelKeepsPinnedLevelOnReturn"] = playlistWindow.level == .floating
        windowGroup.setAlwaysOnTop(oldPin,persist:true)
        for (w,f) in zip(windows,original) {w.setFrame(f,display:true)}
        view.spectrum=Array(repeating:0.38,count:37);view.peaks=Array(repeating:0,count:37);view.titleLine="SPECTRUM COLOUR CHECK";view.artistLine="Moderate signal, no speaker output";view.needsDisplay=true
        if let bitmap=view.bitmapImageRepForCachingDisplay(in:NSRect(x:18,y:69,width:100,height:24)) {
            view.cacheDisplay(in:NSRect(x:18,y:69,width:100,height:24),to:bitmap)
            var greenPixels=0,yellowPixels=0,amberPixels=0
            for x in 0..<bitmap.pixelsWide {for y in 0..<bitmap.pixelsHigh {
                if let c=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),c.brightnessComponent>0.65,c.saturationComponent>0.3 {
                    let hue=c.hueComponent
                    if hue>=0.18 && hue<0.45 {greenPixels+=1}
                    if hue>=0.11 && hue<0.18 {yellowPixels+=1}
                    if hue>=0.03 && hue<0.11 {amberPixels+=1}
                }
            }}
            spectrumPixelCounts=["green":greenPixels,"yellow":yellowPixels,"amber":amberPixels]
            checks["moderateSignalRendersGreenYellowAmber"] = greenPixels>5 && yellowPixels>5 && amberPixels>5
            try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("spectrum-colours.png"))
        } else {checks["moderateSignalRendersGreenYellowAmber"]=false}
        saveModuleRenders(URL(fileURLWithPath:path).deletingLastPathComponent(),prefix:"group")
        checks["passed"]=checks.values.allSatisfy {$0 as? Bool==true};checks["spectrumPixels"]=spectrumPixelCounts;writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
