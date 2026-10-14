import AppKit

@MainActor final class WindowGroup:NSObject,NSWindowDelegate {
    private(set) var windows:[RetroWindow]=[]
    private weak var player:RetroWindow?
    private var raising=false,moving=false,dragging=false
    private var lastPlayerOrigin:NSPoint = .zero
    private var dragReleaseTimer:Timer?
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
    func beginPlayerDrag() {endPlayerDrag();guard let player else {return};lastPlayerOrigin=player.frame.origin;dragging=true}
    func endPlayerDrag() {if dragging {moveCompanions()};dragging=false;dragReleaseTimer?.invalidate();dragReleaseTimer=nil}
    func dragPlayer(with event:NSEvent) {
        guard let player else {return}
        beginPlayerDrag()
        // Window Server performs the drag asynchronously and may consume mouseUp.
        // Keep coupling active until the physical button is released, including tracking modes.
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {timer.invalidate();return}
                if NSEvent.pressedMouseButtons & 1 == 0 {self.endPlayerDrag()}
            }
        }
        dragReleaseTimer=timer;RunLoop.main.add(timer,forMode:.common)
        player.performDrag(with:event)
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
        for w in windows where w !== player && !w.isMiniaturized {w.setFrameOrigin(NSPoint(x:w.frame.minX+delta.x,y:w.frame.minY+delta.y))}
    }
}
