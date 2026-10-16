import AppKit

final class VideoFrameView:NSImageView {
    override func mouseDown(with event:NSEvent){(superview as?VideoCanvas)?.onToggle?()}
}
final class VideoCanvas:NSView {
    override var isFlipped:Bool {true}
    override var isOpaque:Bool {true}
    private let frameView=VideoFrameView(frame:.zero)
    var image:NSImage? {didSet {
        frameView.image=image;frameView.isHidden=image==nil
        if (oldValue==nil) != (image==nil){needsDisplay=true}
    }}
    var message="Оберіть пісню YouTube Music" {didSet {setAccessibilityValue(message);needsDisplay=true}}
    var onToggle:(()->Void)?
    override init(frame:NSRect) {super.init(frame:frame);wantsLayer=true;layerContentsRedrawPolicy = .onSetNeedsDisplay
        frameView.frame=bounds;frameView.autoresizingMask=[.width,.height];frameView.imageScaling = .scaleProportionallyUpOrDown;frameView.imageAlignment = .alignCenter
        frameView.isEditable=false;frameView.animates=false;frameView.wantsLayer=true;frameView.isHidden=true;frameView.setAccessibilityElement(false);addSubview(frameView)
        setAccessibilityElement(true);setAccessibilityRole(.image);setAccessibilityLabel("Кліп поточної пісні")}
    required init?(coder:NSCoder) {fatalError()}
    override func mouseDown(with event:NSEvent) {onToggle?()}
    override func draw(_ rect:NSRect) {
        fill(bounds,.black)
        if image==nil {
            let label=NSAttributedString(string:message,attributes:[.font:drawingFont(size:11,bold:false),.foregroundColor:dimGreen])
            let r=NSRect(x:20,y:max(10,(bounds.height-50)/2),width:max(20,bounds.width-40),height:50);label.draw(in:r)
        }
    }
}
final class VideoPanel:NSView {
    override var isFlipped:Bool {true}
    let canvas=VideoCanvas(frame:.zero)
    let closeButton=MetalButton(frame:.zero)
    let caption=NSTextField(labelWithString:"VIDEO")
    let qualityPopup=NSPopUpButton(frame:.zero,pullsDown:false)
    let qualityStatus=NSTextField(labelWithString:"AUTO")
    var onQuality:((VideoQuality)->Void)?
    var onClose:(()->Void)?
    override init(frame:NSRect) {
        super.init(frame:frame);addSubview(canvas);addSubview(caption);addSubview(closeButton)
        addSubview(qualityPopup);addSubview(qualityStatus)
        qualityPopup.addItems(withTitles:VideoQuality.allCases.map(\.title));qualityPopup.selectItem(at:VideoQuality.allCases.firstIndex(of:VideoQuality.load()) ?? 0)
        qualityPopup.font=drawingFont(size:9,bold:true);qualityPopup.controlSize = .mini
        qualityPopup.setAccessibilityLabel("Якість відео");qualityPopup.target=self;qualityPopup.action=#selector(changeQuality)
        qualityStatus.font=drawingFont(size:9,bold:false);qualityStatus.textColor=dimGreen;qualityStatus.lineBreakMode = .byTruncatingTail
        qualityStatus.setAccessibilityLabel("Фактична роздільність відео")
        caption.font=drawingFont(size:9,bold:false);caption.textColor=green;caption.lineBreakMode = .byTruncatingTail
        closeButton.title="×";closeButton.isBordered=false;closeButton.setAccessibilityLabel("Приховати VIDEO");closeButton.target=self;closeButton.action=#selector(closeVideo)
    }
    required init?(coder:NSCoder) {fatalError()}
    @objc func changeQuality() {let i=qualityPopup.indexOfSelectedItem;guard VideoQuality.allCases.indices.contains(i) else {return};onQuality?(VideoQuality.allCases[i])}
    func showQuality(_ state:VideoQualityState) {qualityStatus.stringValue=state.label;qualityStatus.toolTip="Роздільність декодованого потоку. YouTube може тимчасово знижувати якість під час буферизації."}
    @objc func closeVideo() {onClose?()}
    override func layout() {
        super.layout();canvas.frame=NSRect(x:7,y:23,width:max(1,bounds.width-14),height:max(1,bounds.height-69));caption.frame=NSRect(x:10,y:bounds.height-42,width:bounds.width-32,height:14);qualityStatus.frame=NSRect(x:10,y:bounds.height-21,width:max(20,bounds.width-115),height:14);qualityPopup.frame=NSRect(x:bounds.width-99,y:bounds.height-25,width:82,height:20);closeButton.frame=NSRect(x:bounds.width-22,y:4,width:13,height:12)
    }
    override func draw(_ rect:NSRect) {
        fill(bounds,graphite);bevel(bounds)
        let x=bounds.midX-25
        for y in [7.0,10.0] {fill(NSRect(x:10,y:y,width:max(0,x-15),height:1),.lightGray);fill(NSRect(x:x+55,y:y,width:max(0,bounds.width-x-85),height:1),.lightGray)}
        text("VIDEO",NSRect(x:x,y:3,width:50,height:14),size:9,bold:true)
        bevel(canvas.frame.insetBy(dx:-1,dy:-1),recessed:true)
    }
    override func mouseDown(with event:NSEvent) {if convert(event.locationInWindow,from:nil).y<21,let w=window as? RetroWindow {w.group?.dragWindow(w,with:event)}}
}

@MainActor extension AppDelegate {
    func setVideoVisible(_ visible:Bool,persist:Bool=true) {
        videoVisible=visible;if persist {UserDefaults.standard.set(visible,forKey:"video.visible")}
        if visible {videoWindow.makeKeyAndOrderFront(nil)} else {videoWindow.orderOut(nil)}
        engine.videoVisible=visible;updateVideoButton()
    }
    func updateVideoButton() {for b in view.subviews.compactMap({$0 as? MetalButton}) where b.identifier?.rawValue=="toggleVideo" {b.skinSelected=videoVisible}}
    @objc func focusVideo() {setVideoVisible(true)}
    func updateVideoTrack() {
        videoPanel.canvas.image=nil
        videoPanel.qualityStatus.stringValue=current?.localURL != nil ? "ЛОКАЛЬНЕ АУДІО" : "Очікую відео"
        videoPanel.canvas.message=current?.localURL != nil ? "VIDEO доступне для пісень YouTube Music" : current==nil ? "Оберіть пісню YouTube Music" : "Завантажую кліп…"
        videoPanel.caption.stringValue=current?.title ?? "VIDEO"
    }
}
