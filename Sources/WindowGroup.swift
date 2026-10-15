import AppKit

@MainActor final class WindowGroup:NSObject,NSWindowDelegate {
    private(set) var windows:[RetroWindow]=[]
    private weak var player:RetroWindow?
    private var raising=false,moving=false,dragging=false
    private var lastPlayerOrigin:NSPoint = .zero
    private var dragReleaseTimer:Timer?
    private var dragMembers:[RetroWindow]=[]
    private weak var draggedWindow:RetroWindow?
    private(set) var alwaysOnTop=UserDefaults.standard.bool(forKey:"windows.alwaysOnTop")
    var onPinChange:((Bool)->Void)?
    func configure(player:RetroWindow,windows:[RetroWindow]) {
        self.player=player;self.windows=windows;lastPlayerOrigin=player.frame.origin
        for w in windows {w.group=self;w.delegate=self}
        applyLevel()
    }
    func setAlwaysOnTop(_ pinned:Bool,persist:Bool=true) {
        alwaysOnTop=pinned;applyLevel()
        if persist {UserDefaults.standard.set(pinned,forKey:"windows.alwaysOnTop")}
        onPinChange?(pinned)
    }
    private func applyLevel() {for w in windows {w.level=alwaysOnTop ? .floating : .normal}}
    func bringForward(_ selected:RetroWindow) {
        guard !raising,windows.contains(where:{$0===selected}) else {return}
        raising=true;defer {raising=false;for w in windows {w.contentView?.needsDisplay=true}}
        for w in windows where w !== selected && w.isVisible && !w.isMiniaturized {w.orderFront(nil)}
        if selected.isVisible && !selected.isMiniaturized {selected.makeKeyAndOrderFront(nil)}
        for w in windows {w.attachedSheet?.orderFront(nil)}
        selected.attachedSheet?.makeKeyAndOrderFront(nil)
    }
    func windowDidBecomeKey(_ notification:Notification) {
        if let w=notification.object as? RetroWindow {bringForward(w)}
    }
    // Only native title dragging couples positions; resizing/programmatic layout stays independent.
    static func touches(_ a:NSRect,_ b:NSRect)->Bool {
        let horizontal=min(a.maxX,b.maxX)-max(a.minX,b.minX),vertical=min(a.maxY,b.maxY)-max(a.minY,b.minY)
        return (horizontal>=24 && min(abs(a.minY-b.maxY),abs(a.maxY-b.minY))<=10)
            || (vertical>=24 && min(abs(a.minX-b.maxX),abs(a.maxX-b.minX))<=10)
    }
    func dockedWindows()->[RetroWindow] {
        guard let player else {return []}
        var connected=[player],remaining=windows.filter {$0 !== player && !$0.isMiniaturized}
        while let index=remaining.firstIndex(where:{candidate in connected.contains {Self.touches($0.frame,candidate.frame)}}) {connected.append(remaining.remove(at:index))}
        return connected
    }
    func beginPlayerDrag() {endPlayerDrag();guard let player else {return};lastPlayerOrigin=player.frame.origin;dragMembers=dockedWindows();dragging=true}
    func endPlayerDrag() {
        if dragging {moveCompanions()}
        dragging=false;dragMembers=[];dragReleaseTimer?.invalidate();dragReleaseTimer=nil
        if let w=draggedWindow,w !== player {snap(w)};draggedWindow=nil
    }
    private func snap(_ w:RetroWindow) {
        var best:NSPoint?,distance:CGFloat=13
        let a=w.frame
        for other in windows where other !== w && other.isVisible && !other.isMiniaturized {
            let b=other.frame
            var candidates:[NSPoint]=[]
            if min(a.maxX,b.maxX)-max(a.minX,b.minX)>=24 {
                for dy in [b.maxY-a.minY,b.minY-a.maxY] where abs(dy)<=12 {
                    let dx=abs(a.minX-b.minX)<=12 ? b.minX-a.minX : abs(a.maxX-b.maxX)<=12 ? b.maxX-a.maxX : 0
                    candidates.append(NSPoint(x:dx,y:dy))
                }
            }
            if min(a.maxY,b.maxY)-max(a.minY,b.minY)>=24 {
                for dx in [b.maxX-a.minX,b.minX-a.maxX] where abs(dx)<=12 {
                    let dy=abs(a.maxY-b.maxY)<=12 ? b.maxY-a.maxY : abs(a.minY-b.minY)<=12 ? b.minY-a.minY : 0
                    candidates.append(NSPoint(x:dx,y:dy))
                }
            }
            for delta in candidates {let d=max(abs(delta.x),abs(delta.y));if d<distance {distance=d;best=delta}}
        }
        if let delta=best {w.setFrameOrigin(NSPoint(x:a.minX+delta.x,y:a.minY+delta.y))}
    }
    func dragPlayer(with event:NSEvent) {
        guard let player else {return}
        dragWindow(player,with:event)
    }
    func dragWindow(_ window:RetroWindow,with event:NSEvent) {
        if window===player {beginPlayerDrag()} else {endPlayerDrag()}
        draggedWindow=window
        // Window Server performs the drag asynchronously and may consume mouseUp.
        // Keep coupling active until the physical button is released, including tracking modes.
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {timer.invalidate();return}
                if NSEvent.pressedMouseButtons & 1 == 0 {self.endPlayerDrag()}
            }
        }
        dragReleaseTimer=timer;RunLoop.main.add(timer,forMode:.common)
        window.performDrag(with:event)
    }
    func windowDidMove(_ notification:Notification) {
        guard let w=notification.object as? NSWindow,w===player else {return}
        if dragging {moveCompanions()} else if let player {lastPlayerOrigin=player.frame.origin}
    }
    private func moveCompanions() {
        guard !moving,let player else {return}
        let origin=player.frame.origin,delta=NSPoint(x:origin.x-lastPlayerOrigin.x,y:origin.y-lastPlayerOrigin.y)
        lastPlayerOrigin=origin
        guard delta.x != 0 || delta.y != 0 else {return}
        moving=true;defer {moving=false}
        for w in dragMembers where w !== player && !w.isMiniaturized {w.setFrameOrigin(NSPoint(x:w.frame.minX+delta.x,y:w.frame.minY+delta.y))}
    }
}
