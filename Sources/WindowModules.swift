import AppKit
import UniformTypeIdentifiers

final class ModuleContainer:NSView {
    override var isFlipped:Bool {true}
    let module:NSView
    let baseSize:NSSize?
    private let grip=ResizeGrip(frame:.zero)
    init(module:NSView,baseSize:NSSize?) {
        self.module=module;self.baseSize=baseSize
        super.init(frame:module.frame);addSubview(module);addSubview(grip)
        autoresizingMask=[.width,.height]
    }
    required init?(coder:NSCoder) {fatalError()}
    override func layout() {
        super.layout();module.frame=bounds
        if let baseSize {module.bounds=NSRect(origin:.zero,size:baseSize)}
        grip.frame=NSRect(x:bounds.width-16,y:bounds.height-16,width:16,height:16)
    }
}
final class ResizeGrip:NSView {
    override var isFlipped:Bool {true}
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityLabel("Змінити розмір вікна");setAccessibilityRole(.button)}
    required init?(coder:NSCoder) {fatalError()}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.65,alpha:0.75).setStroke()
        for i in [4.0,8.0,12.0] {let p=NSBezierPath();p.move(to:NSPoint(x:i,y:14));p.line(to:NSPoint(x:14,y:i));p.lineWidth=1;p.stroke()}
    }
    override func mouseDown(with event:NSEvent) {
        guard let window else {return}
        let initial=window.frame,start=window.convertPoint(toScreen:event.locationInWindow)
        var current:NSEvent?=event
        while let e=current {
            let p=window.convertPoint(toScreen:e.locationInWindow)
            let width=min(window.maxSize.width,max(window.minSize.width,initial.width+p.x-start.x))
            let height=min(window.maxSize.height,max(window.minSize.height,initial.height-p.y+start.y))
            window.setFrame(NSRect(x:initial.minX,y:initial.maxY-height,width:width,height:height),display:true)
            if e.type == .leftMouseUp {break}
            current=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp])
        }
    }
}
final class PlaylistPanel:NSView {
    override var isFlipped:Bool {true}
    weak var owner:RetroView?
    let closeButton=MetalButton(frame:.zero)
    init(owner:RetroView) {
        self.owner=owner;super.init(frame:NSRect(x:0,y:0,width:360,height:190))
        registerForDraggedTypes([.fileURL]);addSubview(owner.query);addSubview(owner.scroll);addSubview(owner.statusLabel)
        for b in owner.playlistButtons {addSubview(b)}
        closeButton.title="×";closeButton.skinRole="playlistClose";closeButton.identifier=NSUserInterfaceItemIdentifier("togglePlaylist");closeButton.target=owner;closeButton.action=#selector(RetroView.buttonPressed(_:));closeButton.isBordered=false;closeButton.setAccessibilityLabel("Приховати плейлист");addSubview(closeButton)
    }
    required init?(coder:NSCoder) {fatalError()}
    override func layout() {
        super.layout();guard let owner else {return}
        closeButton.frame=activeSkin==nil ? NSRect(x:bounds.width-22,y:4,width:13,height:12) : NSRect(x:bounds.width-13,y:3,width:9,height:9)
        owner.scroll.frame=NSRect(x:12,y:24,width:bounds.width-24,height:max(50,bounds.height-75))
        owner.table.tableColumns.first?.width=max(100,owner.scroll.contentSize.width)
        owner.statusLabel.frame=NSRect(x:12,y:bounds.height-17,width:bounds.width-40,height:11)
        let y=bounds.height-42
        owner.query.frame=NSRect(x:12,y:y,width:max(92,bounds.width-164),height:20)
        for (i,b) in owner.playlistButtons.enumerated() {b.frame=NSRect(x:bounds.width-146+CGFloat([0,68,102,126][i]),y:y,width:CGFloat([64,30,20,20][i]),height:20)}
    }
    override func mouseDown(with event:NSEvent) {if convert(event.locationInWindow,from:nil).y<21 {if let w=window as? RetroWindow,let group=w.group {group.dragWindow(w,with:event)} else {window?.performDrag(with:event)}}}
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {owner?.draggingEntered(sender) ?? []}
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {owner?.performDragOperation(sender) ?? false}
    override func draw(_ dirtyRect:NSRect) {
        guard let owner else {return}
        if let skin=activeSkin,skin.drawPlaylist(in:bounds,selected:window?.isKeyWindow==true) {return}
        fill(bounds,graphite);bevel(bounds)
        let title=owner.sectionTitle.uppercased(),w=min(bounds.width-70,CGFloat(title.count)*6+8),x=(bounds.width-w)/2
        let accent=NSColor(calibratedRed:0.80,green:0.75,blue:0.51,alpha:1)
        for y in [7.0,10.0] {fill(NSRect(x:10,y:y,width:max(0,x-15),height:1),accent);fill(NSRect(x:x+w+5,y:y,width:max(0,bounds.width-x-w-33),height:1),accent)}
        text(title,NSRect(x:x,y:3,width:w,height:14),size:9,bold:true)
        fill(owner.scroll.frame.insetBy(dx:-2,dy:-2),.black);bevel(owner.scroll.frame.insetBy(dx:-2,dy:-2),recessed:true)
    }
}

@MainActor extension AppDelegate {
    func makeWindows() {
        func module(_ content:NSView,base:NSSize?,title:String,size:NSSize,key:String)->RetroWindow {
            let w=RetroWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.resizable,.miniaturizable],backing:.buffered,defer:false)
            w.title=title;w.isOpaque=true;w.hasShadow=true;w.isReleasedWhenClosed=false;w.minSize=NSSize(width:275,height:title.contains("Плейлист") ? 150 : title.contains("Еквалайзер") ? 107 : 127);w.maxSize=NSSize(width:1280,height:1000)
            w.contentView=ModuleContainer(module:content,baseSize:base);return w
        }
        window=module(view,base:NSSize(width:360,height:146),title:"Retroamp — Плеєр",size:NSSize(width:320,height:130),key:"retroamp.main.v6")
        equalizerWindow=module(view.equalizerView,base:NSSize(width:360,height:140),title:"Retroamp — Еквалайзер",size:NSSize(width:320,height:124),key:"retroamp.eq.v6")
        playlistWindow=module(view.playlistView,base:nil,title:"Retroamp — Плейлист",size:NSSize(width:320,height:200),key:"retroamp.playlist.v6")
        videoWindow=module(videoPanel,base:nil,title:"Retroamp — VIDEO",size:NSSize(width:480,height:318),key:"retroamp.video.v1");videoWindow.minSize=NSSize(width:320,height:220);videoWindow.maxSize=NSSize(width:1920,height:1200)
        arrangeWindows(nil)
        for (w,key) in [(window!,"retroamp.main.v6"),(equalizerWindow!,"retroamp.eq.v6"),(playlistWindow!,"retroamp.playlist.v6"),(videoWindow!,"retroamp.video.v1")] {
            _=w.setFrameUsingName(key);w.setFrameAutosaveName(key)
            if let screen=NSScreen.screens.first(where:{$0.visibleFrame.intersects(w.frame)}),screen.visibleFrame.intersection(w.frame).width>=80,screen.visibleFrame.intersection(w.frame).height>=40 {} else {w.center()}
            w.contentView?.layoutSubtreeIfNeeded()
        }
        windowGroup.configure(player:window,windows:[window,equalizerWindow,playlistWindow,videoWindow])
    }
    func updatePinButton(_ enabled:Bool) {
        if let pin=view.subviews.compactMap({$0 as? MetalButton}).first(where:{$0.identifier?.rawValue=="pin"}) {pin.skinSelected=enabled;pin.setAccessibilityValue(enabled ? "Увімкнено" : "Вимкнено");pin.needsDisplay=true}
    }
    func showModules() {
        guard equalizerWindow != nil,playlistWindow != nil else {return}
        if view.eqVisible {if !equalizerWindow.isVisible {equalizerWindow.makeKeyAndOrderFront(nil)}} else {equalizerWindow.orderOut(nil)}
        if view.playlistVisible {if !playlistWindow.isVisible {playlistWindow.makeKeyAndOrderFront(nil)}} else {playlistWindow.orderOut(nil)}
        if videoVisible {if !videoWindow.isVisible {videoWindow.orderFront(nil)}} else {videoWindow.orderOut(nil)}
    }
    @objc func arrangeWindows(_ sender:Any?) {
        guard window != nil,equalizerWindow != nil,playlistWindow != nil else {return}
        let screen=(window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x:0,y:0,width:1000,height:800)
        let x=screen.midX-160,top=screen.midY+240
        window.setFrame(NSRect(x:x,y:top-130,width:320,height:130),display:true)
        equalizerWindow.setFrame(NSRect(x:x,y:top-130-4-124,width:320,height:124),display:true)
        playlistWindow.setFrame(NSRect(x:x,y:top-130-4-124-4-200,width:320,height:200),display:true)
        videoWindow?.setFrame(NSRect(x:x+324,y:top-318,width:480,height:318),display:true)
    }
    var skinStorageURL:URL {FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Retroamp",isDirectory:true).appendingPathComponent(Bundle.main.bundleIdentifier ?? "command-line",isDirectory:true).appendingPathComponent("active-skin.wsz")}
    @objc func openSkin(_ sender:Any?) {
        guard window.attachedSheet==nil,!installingSession else {return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"wsz") ?? .data];panel.canChooseDirectories=false;panel.title="Відкрити класичний скін Winamp 2";panel.prompt="Застосувати"
        panel.beginSheetModal(for:window) {[weak self] response in if response == .OK,let url=panel.url {self?.loadSkin(url)}}
    }
    @objc func useDefaultSkin(_ sender:Any?) {
        skinTask?.cancel();activeSkin=nil;try? FileManager.default.removeItem(at:skinStorageURL);refreshSkin();status("ОСНОВНИЙ СКІН RETROAMP")
    }
    func loadSkin(_ url:URL,persist:Bool=true) {
        skinTask?.cancel();status("ЗАВАНТАЖУЮ СКІН…")
        skinTask=Task { @MainActor in
            let scoped=url.startAccessingSecurityScopedResource();defer {if scoped {url.stopAccessingSecurityScopedResource()}}
            do {
                let bytes=try await Task.detached {let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size>0,size<=20_000_000 else {throw MusicError.message("Скін має бути меншим за 20 MB.")};return try Data(contentsOf:url)}.value
                try Task.checkCancellation();let skin=try WSZSkin(data:bytes,name:url.deletingPathExtension().lastPathComponent)
                if persist {let target=skinStorageURL;try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true);try bytes.write(to:target,options:.atomic)}
                activeSkin=skin;refreshSkin();status("СКІН: "+skin.name)
            } catch {if !Task.isCancelled {status("Не вдалося застосувати скін: "+error.localizedDescription)}}
        }
    }
    func refreshSkin() {
        view.applySkinLayout();view.playlistView.needsLayout=true;view.playlistView.layoutSubtreeIfNeeded();view.table.backgroundColor=activeSkin?.backgroundColor ?? .black;view.scroll.backgroundColor=activeSkin?.backgroundColor ?? .black;view.table.reloadData()
        for w in [window,equalizerWindow,playlistWindow] {w?.contentView?.needsDisplay=true;w?.contentView?.displayIfNeeded()}
    }
    func addAppearanceMenu(to menu:NSMenu) {
        let root=NSMenuItem();root.title="Вигляд";let appearance=NSMenu(title:"Вигляд")
        for (label,selector,key) in [("Завантажити скін Winamp 2…",#selector(openSkin(_:)),""),("Основний скін Retroamp",#selector(useDefaultSkin(_:)),""),("Зібрати вікна",#selector(arrangeWindows(_:)),"")] {let item=NSMenuItem(title:label,action:selector,keyEquivalent:key);item.target=self;appearance.addItem(item)}
        root.submenu=appearance;menu.addItem(root)
    }
}
