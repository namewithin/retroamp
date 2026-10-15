import AppKit

enum TransportState {
    case idle,loading,playing,paused,stopped,failed
    var label:String {switch self {case .idle:return "READY";case .loading:return "LOAD";case .playing:return "PLAY";case .paused:return "PAUSE";case .stopped:return "STOP";case .failed:return "ERROR"}}
    var description:String {switch self {case .idle:return "Готовий";case .loading:return "Завантаження";case .playing:return "Відтворення";case .paused:return "Пауза";case .stopped:return "Зупинено";case .failed:return "Помилка відтворення"}}
}

extension MetalButton {
    var indicatesState:Bool {["play","pause","stop","shuffle","repeat","toggleEQ","togglePlaylist","toggleVideo","eqOn"].contains(skinRole ?? identifier?.rawValue ?? "")}
    func drawStateLamp() {
        guard indicatesState else {return}
        let r=NSRect(x:bounds.maxX-6,y:bounds.maxY-6,width:3,height:3)
        fill(r.insetBy(dx:-1,dy:-1),NSColor(calibratedWhite:0.12,alpha:1))
        fill(r,skinSelected ? green : NSColor(calibratedRed:0.13,green:0.22,blue:0.10,alpha:1))
    }
}

extension RetroView {
    func updateTransport(_ state:TransportState) {
        guard !transportStateInitialized || transportState != state else{return}
        transportStateInitialized=true;transportState=state;isPlaying=state == .playing
        for button in subviews.compactMap({$0 as? MetalButton}) {
            switch button.identifier?.rawValue {
            case "play":button.skinSelected=state == .playing
            case "pause":button.skinSelected=state == .paused
            case "stop":button.skinSelected=state == .stopped
            default:break
            }
        }
        transportIndicator.setAccessibilityValue(state.description);needsDisplay=true
    }
    func updateModes(shuffle:Bool,repeatMode:Int) {
        for button in subviews.compactMap({$0 as? MetalButton}) {
            if button.identifier?.rawValue=="shuffle" {button.skinSelected=shuffle;button.setAccessibilityLabel("Випадковий порядок")}
            if button.identifier?.rawValue=="repeat" {
                button.skinSelected=repeatMode>0;button.title=repeatMode==2 ? "REP1" : "REP"
                button.setAccessibilityLabel("Повторення");button.setAccessibilityValue(["Вимкнено","Повторення черги","Повторення одного треку"][repeatMode]);button.toolTip=["Повторення вимкнено","Повторювати чергу","Повторювати один трек"][repeatMode]
            }
        }
    }
    func drawTransportIndicator(in rect:NSRect) {
        let color:NSColor=transportState == .playing ? green : transportState == .paused || transportState == .loading ? .systemYellow : transportState == .failed ? .systemRed : dimGreen
        color.setFill()
        switch transportState {
        case .playing:
            let path=NSBezierPath();path.move(to:NSPoint(x:rect.minX,y:rect.minY));path.line(to:NSPoint(x:rect.maxX,y:rect.midY));path.line(to:NSPoint(x:rect.minX,y:rect.maxY));path.close();path.fill()
        case .paused:fill(NSRect(x:rect.minX,y:rect.minY,width:3,height:rect.height),color);fill(NSRect(x:rect.maxX-3,y:rect.minY,width:3,height:rect.height),color)
        case .loading:NSBezierPath(ovalIn:rect.insetBy(dx:1,dy:1)).fill()
        default:fill(rect.insetBy(dx:1,dy:1),color)
        }
    }
}

@MainActor extension AppDelegate {
    func transportKeyAction(_ event:NSEvent)->String? {
        let panels=[window,equalizerWindow,playlistWindow,videoWindow].compactMap {$0}
        guard !installingSession,!event.isARepeat,panels.contains(where:{$0 === event.window}),
              panels.allSatisfy({$0.attachedSheet==nil}),
              !(event.window?.firstResponder is NSTextView),!(event.window?.firstResponder is NSTextField),
              event.modifierFlags.intersection([.command,.option,.control]).isEmpty else {return nil}
        // Physical Z/X/C/V/B positions also work with a Ukrainian keyboard layout.
        return [6:"previous",7:"play",8:"togglePlayback",9:"stop",11:"next",49:"togglePlayback"][event.keyCode]
    }
    func previousTrack() {
        guard let item=current else {return}
        guard lastState?.ad != true else {status("РЕКЛАМА • ПЕРЕМОТУВАННЯ НЕДОСТУПНЕ");return}
        let now=ProcessInfo.processInfo.systemUptime
        let justRewound=previousRewind?.id==item.id && now <= (previousRewind?.until ?? 0)
        if queueIndex<=0 || (!justRewound && (lastState?.time ?? 0)>3) {
            previousRewind=(item.id,now+2)
            engine.rewind();view.updateClock(time:0,duration:lastState?.duration ?? view.duration);view.seek.value=0
            status("НА ПОЧАТОК ПОТОЧНОГО ТРЕКУ")
            return
        }
        previousRewind=nil;advance(-1)
    }
    func toggleShuffle() {
        guard !queue.isEmpty else {status("СПОЧАТКУ ВІДКРИЙТЕ ТРЕК");return}
        let active=current
        shuffleEnabled.toggle()
        if shuffleEnabled {
            orderedQueue=queue
            var rest=queue.filter {$0.id != active?.id};rest.shuffle()
            queue=active.map {[$0]+rest} ?? rest
        } else {
            var seen=Set(orderedQueue.map(\.id));orderedQueue+=queue.filter {seen.insert($0.id).inserted};queue=orderedQueue
        }
        queueIndex=queue.firstIndex(where:{$0.id==active?.id}) ?? -1
        view.updateModes(shuffle:shuffleEnabled,repeatMode:repeatMode);refreshMediaCommands()
        status(shuffleEnabled ? "ВИПАДКОВИЙ ПОРЯДОК УВІМКНЕНО" : "ВИПАДКОВИЙ ПОРЯДОК ВИМКНЕНО")
    }
    func configureQueue(_ tracks:[MusicItem],starting item:MusicItem) {
        orderedQueue=tracks;queue=tracks
        if shuffleEnabled {var rest=tracks.filter {$0.id != item.id};rest.shuffle();queue=[item]+rest}
        queueIndex=queue.firstIndex(where:{$0.id==item.id}) ?? 0;refreshMediaCommands()
    }
}
