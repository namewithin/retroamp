import AppKit

@MainActor extension AppDelegate {
    func checkNativeStream(_ path:String,fixture:URL)async {
        var checks:[String:Any]=["speakerOutput":false,"personalCredentials":false]
        var maxLevel:Float=0,frames=0
        let receiveSpectrum=engine.onSpectrum
        engine.onSpectrum={levels in if let peak=levels.max(),peak>0.02{frames+=1;maxLevel=max(maxLevel,peak)};receiveSpectrum?(levels)}
        func waitFor(_ predicate:()->Bool)async throws {
            for _ in 0..<120{if predicate(){return};if view.transportState == .failed{throw MusicError.message("Native stream failed: "+(engine.lastBridgeFailure ?? view.status))};try await Task.sleep(nanoseconds:100_000_000)}
            throw MusicError.message("Native stream check timed out: "+String(describing:engine.streamDiagnostics))
        }
        do {
            engine.volume(0);engine.mute(true);setVideoVisible(false,persist:false)
            let c=try await engine.prepareVideoFixture(fixture)
            let cookie=BrowserCookie(name:"RETROAMP_QA",value:"synthetic-only",domain:"music.youtube.com",path:"/scope",secure:true,httpOnly:true,expires:Date().timeIntervalSince1970+86400,sameSite:"Strict")
            _=try await c.call("Network.setCookies",["cookies":[cookie.parameters,["name":"RETROAMP_FUTURE","value":"synthetic-only","domain":"music.youtube.com","path":"/scope","secure":true,"httpOnly":true,"expires":4_000_000_000.0],["name":"OUT_OF_SCOPE","value":"excluded","domain":".example.com"]]])
            let cookieInfo=try await c.call("Retroamp.cookieInfo")
            let saved=(cookieInfo["cookies"]as?[[String:Any]] ?? []).first{$0["name"]as?String==cookie.name}
            checks["cookieScopeAndSecurityAttributesSurviveMigration"]=saved?["domain"]as?String==cookie.domain && saved?["path"]as?String==cookie.path && saved?["secure"]as?Bool==true && saved?["httpOnly"]as?Bool==true && abs((saved?["expires"]as?Double ?? 0)-cookie.expires)<1
            checks["restoredCookieAttributes"]=saved
            // WebKit demonstrably caps distant expiries to 400 days (HTTPWG policy), not to 2096.
            // Preserve near expiry exactly; a cap may shorten a long cookie but must never extend it.
            let future=(cookieInfo["cookies"]as?[[String:Any]] ?? []).first{$0["name"]as?String=="RETROAMP_FUTURE"}
            let capped=future?["expires"]as?Double ?? 0
            checks["webKitCookieExpiryCapRespected"]=abs(capped-(Date().timeIntervalSince1970+400*86400))<10
            checks["unrelatedCookieDomainRejected"]=(cookieInfo["cookies"]as?[[String:Any]] ?? []).allSatisfy{$0["name"]as?String != "OUT_OF_SCOPE"}
            var flat=EqualizerSettings();flat.enabled=true;flat.preamp=0;flat.gains=Array(repeating:0,count:10);engine.equalizerSettings(flat)
            let track=MusicItem(id:"fixture0001",title:"Native PCM fixture",subtitle:"WebKit / native EQ",videoID:"fixture0001",browseID:nil,duration:"")
            configureQueue([track],starting:track);play(track)
            try await waitFor {self.lastState?.hasSource==true && (self.lastState?.time ?? 0)>0.4 && frames>=3}
            checks["webKitDrivesRealNativePCM"]=engine.streamDiagnostics["tapStarted"]as?Bool==true && frames>=3
            checks["sourceIdentity"]=engine.streamDiagnostics
            checks["flatSpectrumPeak"]=maxLevel
            let baseline=maxLevel;maxLevel=0;var boost=flat;boost.gains=Array(repeating:9,count:10);engine.equalizerSettings(boost)
            try await Task.sleep(nanoseconds:600_000_000)
            checks["boostedSpectrumPeak"]=maxLevel;checks["liveNativeEQChangesSpectrum"]=maxLevel>baseline+0.05
            engine.equalizerSettings(flat)
            let browser=try await c.evaluate("({singleMedia:document.querySelectorAll('video,audio').length===1,webAudioGraph:typeof window.__retroamp.graph!=='undefined',nativePipe:window.__retroNativePipe,sourceVolume:document.querySelector('video').volume})")
            checks["oneMediaElementWithoutWebAudioGraph"]=browser["singleMedia"]as?Bool==true && browser["webAudioGraph"]as?Bool==false && browser["nativePipe"]as?Bool==true
            checks["sourceIsLimitedToOnePercent"]=abs((browser["sourceVolume"]as?Double ?? 99)-0.01)<0.00001
            checks["nativeOutputRemainsMuted"]=engine.streamDiagnostics["nativeOutputVolume"]as?Float==0
            act("pause");try await waitFor{self.lastState?.paused==true};let time=lastState?.time ?? -100
            try await Task.sleep(nanoseconds:500_000_000)
            checks["pausePreservesClockAndTap"]=abs((lastState?.time ?? 0)-time)<0.1 && engine.streamDiagnostics["tapStarted"]as?Bool==true
            engine.seek(0.5);try await waitFor{abs((self.lastState?.time ?? 0)-7)<0.3}
            checks["seekWhilePaused"]=lastState?.paused==true
            act("play");try await waitFor{self.lastState?.paused==false && (self.lastState?.time ?? 0)>7.2}
            checks["resumeAfterSeek"]=true
            let firstDocument=c.sourceInfo["documentGeneration"]as?Int ?? -1
            _=try await c.request("reload")
            var reloaded=false
            for _ in 0..<60{let info=try await c.request("sourceInfo");if (info["documentGeneration"]as?Int ?? -1)>firstDocument{reloaded=true;break};try await Task.sleep(nanoseconds:50_000_000)}
            guard reloaded else{throw MusicError.message("Helper did not reload a real document")}
            _=try await engine.prepareVideoFixture(fixture)
            let second=MusicItem(id:"fixture0002",title:"After navigation",subtitle:"Native PCM must resume",videoID:"fixture0002",browseID:nil,duration:"")
            frames=0;configureQueue([second],starting:second);play(second)
            try await waitFor{frames>=3 && (self.lastState?.time ?? 0)>0.3}
            checks["fullNavigationReactivatesNativePCM"]=frames>=3 && (c.sourceInfo["documentGeneration"]as?Int ?? -1)>firstDocument
            _=try await c.evaluate("document.querySelector('video').pause=()=>{throw new Error('synthetic shutdown failure')};({})")
            let before=c.process.processIdentifier
            await engine.installSession(nil)
            await c.waitUntilClosed()
            checks["failedMuteDoesNotClaimQuiet"] = !c.quietConfirmed
            checks["sourceExitsBeforeTapReleased"] = !c.process.isRunning && !c.audio.started
            checks["closedIPCIsIdempotent"]=before>0
            c.close();await c.waitUntilClosed();checks["closedIPCIsIdempotent"] = !c.process.isRunning
            let generation=sessionGeneration
            var continuation:CheckedContinuation<Void,Never>?,reopened=false
            startupTask=Task{@MainActor in await withCheckedContinuation{continuation=$0};guard !Task.isCancelled,generation==self.sessionGeneration else{return};reopened=true}
            while continuation==nil{await Task.yield()}
            cancelWorkForTermination();continuation?.resume();await startupTask?.value
            checks["quitInvalidatesPendingSessionRestore"] = !reopened
            engine.beginShutdown();engine.play("fixture0003");engine.playLocal(fixture)
            try await Task.sleep(nanoseconds:200_000_000)
            checks["quitBarrierPreventsAnyNewAudioSource"] = !engine.isLocal && engine.streamDiagnostics["connected"]as?Bool==false
            checks["passed"]=["cookieScopeAndSecurityAttributesSurviveMigration","unrelatedCookieDomainRejected","webKitCookieExpiryCapRespected","webKitDrivesRealNativePCM","liveNativeEQChangesSpectrum","oneMediaElementWithoutWebAudioGraph","sourceIsLimitedToOnePercent","nativeOutputRemainsMuted","pausePreservesClockAndTap","seekWhilePaused","resumeAfterSeek","sourceExitsBeforeTapReleased","closedIPCIsIdempotent","fullNavigationReactivatesNativePCM","failedMuteDoesNotClaimQuiet","quitInvalidatesPendingSessionRestore","quitBarrierPreventsAnyNewAudioSource"].allSatisfy{checks[$0]as?Bool==true}
        }catch{checks["passed"]=false;checks["failureState"]=["time":lastState?.time ?? -1,"paused":lastState?.paused ?? true,"hasSource":lastState?.hasSource ?? false,"signalFrames":frames];checks["error"]=error.localizedDescription;checks["bridgeFailure"]=(error as?CDPFailure)?.diagnostic ?? engine.lastBridgeFailure ?? "none"}
        engine.onSpectrum=receiveSpectrum;writeCheck(checks,path:path);NSApp.terminate(nil)
    }
}
