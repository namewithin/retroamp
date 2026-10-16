import AppKit
import WebKit
import UniformTypeIdentifiers

let green = NSColor(calibratedRed: 0.60, green: 0.94, blue: 0.18, alpha: 1)
let dimGreen = NSColor(calibratedRed: 0.24, green: 0.35, blue: 0.12, alpha: 1)
let graphite = NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.25, alpha: 1)
let diagnosticBuild=Bundle.main.bundleIdentifier?.hasPrefix("local.retroamp.qa.")==true

private var drawingFonts:[String:NSFont]=[:]
func drawingFont(size:CGFloat,bold:Bool)->NSFont? {
    let key="\(size)-\(bold)"
    if let font=drawingFonts[key] {return font}
    guard let font=NSFont(name:bold ? "Menlo-Bold" : "Menlo-Regular",size:size) else {return nil}
    drawingFonts[key]=font;return font
}
func fill(_ rect: NSRect, _ color: NSColor) { color.setFill(); rect.fill() }
func text(_ string: String, _ rect: NSRect, size: CGFloat = 12, color: NSColor = .lightGray, bold: Bool = false) {
    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byTruncatingTail
    guard let font=drawingFont(size:size,bold:bold) else {return}
    (string as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
}
func bevel(_ rect: NSRect, recessed: Bool = false) {
    let light = NSColor(calibratedWhite: 0.55, alpha: 1), dark = NSColor(calibratedWhite: 0.04, alpha: 1)
    fill(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2), recessed ? dark : light)
    fill(NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height), recessed ? dark : light)
    fill(NSRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2), recessed ? light : dark)
    fill(NSRect(x: rect.maxX - 2, y: rect.minY, width: 2, height: rect.height), recessed ? light : dark)
}

final class MetalButton: NSButton {
    var skinRole:String?
    var skinSelected=false {didSet {guard oldValue != skinSelected else{return};needsDisplay=true;if (indicatesState && skinRole != "repeat") || skinRole=="pin" {setAccessibilityValue(skinSelected ? "Увімкнено" : "Вимкнено")}}}
    override func draw(_ dirtyRect: NSRect) {
        if let skin=activeSkin,let role=skinRole,skin.button(role,pressed:isHighlighted,selected:skinSelected,in:bounds) {if ["play","pause","stop"].contains(role) {drawStateLamp()};return}
        fill(bounds, isHighlighted ? NSColor(calibratedWhite: 0.38, alpha: 1) : skinSelected && skinRole=="pin" ? NSColor(calibratedRed:0.82,green:0.77,blue:0.47,alpha:1) : skinSelected && indicatesState ? NSColor(calibratedRed:0.52,green:0.58,blue:0.50,alpha:1) : NSColor(calibratedRed:0.62,green:0.67,blue:0.72,alpha:1))
        bevel(bounds.insetBy(dx: 1, dy: 1), recessed: isHighlighted)
        drawStateLamp()
        if let role=skinRole ?? identifier?.rawValue,drawIcon(role) {return}
        let size: CGFloat = title.count > 3 ? 8 : 9
        guard let font=drawingFont(size:size,bold:true) else {return}
        let attr: [NSAttributedString.Key: Any] = [.font:font, .foregroundColor:NSColor(calibratedWhite:0.10, alpha:1)]
        let measure = (title as NSString).size(withAttributes: attr)
        (title as NSString).draw(at: NSPoint(x:(bounds.width-measure.width)/2, y:(bounds.height-measure.height)/2), withAttributes: attr)
    }
}

final class RetroSlider: NSControl {
    var value: Double = 0.65 { didSet {needsDisplay = true} }
    var isSeek = false
    override var acceptsFirstResponder:Bool {true}
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.slider)}
    required init?(coder:NSCoder) {fatalError()}
    override func accessibilityValue()->Any? {NSNumber(value:value)}
    override func setAccessibilityValue(_ newValue:Any?) {if let number=newValue as? NSNumber {value=min(1,max(0,number.doubleValue));_ = sendAction(action,to:target)}}
    override func keyDown(with event:NSEvent) {
        if [123,125].contains(event.keyCode) {value=max(0,value-0.02)} else if [124,126].contains(event.keyCode) {value=min(1,value+0.02)} else {super.keyDown(with:event);return}
        _ = sendAction(action,to:target)
    }
    var knobWidth:CGFloat {activeSkin==nil ? 14 : bounds.width*(isSeek ? 29.0/248 : 14.0/68)}
    override func draw(_ dirtyRect: NSRect) {
        if let skin=activeSkin {
            let sheet=isSeek ? "posbar" : "volume",source=isSeek ? NSRect(x:0,y:0,width:248,height:10) : NSRect(x:0,y:CGFloat(Int(value*27))*15,width:68,height:13)
            if skin.draw(sheet,source,bounds) {let knob=isSeek ? NSRect(x:248,y:0,width:29,height:10) : NSRect(x:15,y:422,width:14,height:11);skin.draw(sheet,knob,NSRect(x:CGFloat(value)*(bounds.width-knobWidth),y:0,width:knobWidth,height:bounds.height));return}
        }
        let rail = NSRect(x:2,y:bounds.midY-3,width:bounds.width-4,height:6)
        fill(rail,.black);bevel(rail,recessed:true)
        let activeWidth = CGFloat(value) * (rail.width - 14)
        fill(NSRect(x:rail.minX+2,y:rail.minY+2,width:max(0,activeWidth),height:2),isSeek ? .systemYellow : green)
        let knob = NSRect(x:rail.minX+activeWidth,y:bounds.midY-7,width:14,height:14)
        fill(knob, NSColor(calibratedRed:0.70,green:0.67,blue:0.52,alpha:1));bevel(knob)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        var current: NSEvent? = event
        while let e = current {
            let p = convert(e.locationInWindow,from:nil)
            value = min(1,max(0,Double((p.x-knobWidth/2)/max(1,bounds.width-knobWidth))))
            _ = sendAction(action,to:target)
            if e.type == .leftMouseUp {break}
            current = window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp])
        }
    }
}

final class RetroRow:NSTableRowView {
    override func drawSelection(in dirtyRect:NSRect) {fill(bounds,activeSkin?.selectionColor ?? NSColor(calibratedRed:0.05,green:0.12,blue:0.47,alpha:1))}
}

final class RetroView:NSView {
    override var isFlipped:Bool {true}
    override var isOpaque:Bool {true}
    var status="⌘O — ФАЙЛИ • GOOGLE — YOUTUBE MUSIC" {didSet {statusLabel.stringValue=status;statusLabel.toolTip=status}}
    var titleLine="YOUTUBE MUSIC" {didSet {if oldValue != titleLine {titleMarquee.reset();skinMarquee.reset();setNeedsDisplay(titleDisplayRect)}}}
    var artistLine="Відкрийте файли або підключіть Google." {didSet {if oldValue != artistLine {artistMarquee.reset();skinMarquee.reset();setNeedsDisplay(titleDisplayRect)}}}
    let titleMarquee=MarqueeState(),artistMarquee=MarqueeState(),skinMarquee=MarqueeState()
    let clockControl=DisplayHitControl(),spectrumControl=DisplayHitControl()
    var elapsed:Double=0,duration:Double=0
    var remainingTime=UserDefaults.standard.bool(forKey:"display.remainingTime")
    var wideSpectrum=UserDefaults.standard.bool(forKey:"display.wideSpectrum")
    var lastAnimationTime=ProcessInfo.processInfo.systemUptime
    var rows:[String]=[] {didSet {table.reloadData()}}
    var sectionTitle="PLAYLIST" {didSet {playlistView.needsDisplay=true}}
    var isPlaying=false {didSet {if isPlaying {startDisplayTimer()}}}
    var hasSource=false
    var transportState=TransportState.idle
    var transportStateInitialized=false
    let transportIndicator=NSView()
    var durationLine="",formatLine="STREAM / STEREO"
    var clock="00:00"
    var selected = -1
    let query=NSTextField(),volume=RetroSlider(),seek=RetroSlider()
    let table=NSTableView(),scroll=NSScrollView()
    let statusLabel=NSTextField(labelWithString:"")
    let equalizerView=EqualizerView(frame:NSRect(x:0,y:0,width:360,height:140))
    var spectrum=[Float](repeating:0,count:37),peaks=[Float](repeating:0,count:37)
    var spectrumInput=[Float](repeating:0,count:37)
    let spectrumDynamics=SpectrumDynamics()
    var visualizerSettings=VisualizerSettings.load()
    var spectrumTimer:Timer?
    var onAction:((String)->Void)?
    var onFiles:(([URL])->Void)?
    var eqVisible=true,playlistVisible=true
    var playlistButtons:[NSButton]=[]
    lazy var playlistView=PlaylistPanel(owner:self)
    var onModules:(()->Void)?
    var defaultFrames:[String:NSRect]=[:]
    var playlistY:CGFloat {0}
    override init(frame:NSRect) {
        super.init(frame:frame);wantsLayer=true;layerContentsRedrawPolicy = .onSetNeedsDisplay;registerForDraggedTypes([.fileURL])
        startDisplayTimer()
        for (label,x,width,command) in [("|◀",13.0,28.0,"previous"),("▶",43.0,28.0,"play"),("Ⅱ",73.0,28.0,"pause"),("■",103.0,28.0,"stop"),("▶|",133.0,28.0,"next"),("▲",169.0,28.0,"openFiles"),("SHUF",219.0,61.0,"shuffle"),("REP",282.0,61.0,"repeat")] {
            _=addButton(label,NSRect(x:x,y:115,width:width,height:21),command)
        }
        let pin=addButton("",NSRect(x:308,y:5,width:13,height:11),"pin");pin.setAccessibilityLabel("Завжди зверху");pin.toolTip="Тримати всі вікна поверх інших програм"
        _=addButton("−",NSRect(x:323,y:5,width:13,height:11),"minimize")
        _=addButton("×",NSRect(x:338,y:5,width:13,height:11),"close")
        _=addButton("EQ",NSRect(x:289,y:78,width:27,height:16),"toggleEQ")
        _=addButton("PL",NSRect(x:318,y:78,width:27,height:16),"togglePlaylist")
        _=addButton("VID",NSRect(x:254,y:78,width:32,height:16),"toggleVideo")
        volume.frame=NSRect(x:174,y:78,width:75,height:16);volume.value=0.15;volume.target=self;volume.action=#selector(volumeChanged);volume.setAccessibilityLabel("Гучність");addSubview(volume)
        seek.frame=NSRect(x:12,y:100,width:333,height:12);seek.value=0;seek.isSeek=true;seek.target=self;seek.action=#selector(seekChanged);seek.setAccessibilityLabel("Позиція треку");addSubview(seek)
        query.font = drawingFont(size:9,bold:false);query.placeholderString="Пошук YouTube Music";query.textColor=green;query.backgroundColor = .black;query.isBordered=true;query.focusRingType = .none;query.target=self;query.action=#selector(search);addSubview(query)
        playlistButtons=[addButton("GOOGLE",.zero,"connect"),addButton("LIB",.zero,"library"),addButton("Q",.zero,"queue"),addButton("+",.zero,"favorite")]
        playlistButtons[0].setAccessibilityLabel("Увійти через Google");playlistButtons[1].setAccessibilityLabel("Бібліотека");playlistButtons[2].setAccessibilityLabel("Черга");playlistButtons[3].setAccessibilityLabel("Додати поточний трек до улюблених");playlistButtons[3].toolTip="Додати поточний трек до улюблених"
        let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("track"));column.width=330;table.addTableColumn(column);table.headerView=nil;table.rowHeight=18;table.intercellSpacing = .zero;table.backgroundColor = .black;table.selectionHighlightStyle = .regular;table.gridStyleMask=[]
        scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.borderType = .noBorder;scroll.backgroundColor = .black;addSubview(scroll)
        statusLabel.font = drawingFont(size:8,bold:false);statusLabel.textColor=NSColor(calibratedWhite:0.70,alpha:1);statusLabel.lineBreakMode = .byTruncatingTail;statusLabel.stringValue=status
        clockControl.setAccessibilityLabel("Час треку: минув / залишилось");clockControl.toolTip="Клік: час, що минув / залишилось";clockControl.target=self;clockControl.action=#selector(toggleClock);addSubview(clockControl)
        spectrumControl.setAccessibilityLabel("Спектр: вузькі / широкі смуги");spectrumControl.toolTip="Клік: вузькі / широкі смуги";spectrumControl.target=self;spectrumControl.action=#selector(toggleSpectrum);addSubview(spectrumControl)
        applySkinLayout();arrangeModules();updateClock(time:0,duration:0)
        transportIndicator.setAccessibilityElement(true);transportIndicator.setAccessibilityRole(.staticText);transportIndicator.setAccessibilityLabel("Стан відтворення");addSubview(transportIndicator);updateTransport(.idle)
    }
    required init?(coder:NSCoder) {fatalError()}
    deinit {for observer in animationObservers {NotificationCenter.default.removeObserver(observer)};spectrumTimer?.invalidate()}
    private var animationObservers:[NSObjectProtocol]=[]
    private var needsAnimation:Bool {isPlaying || spectrumDynamics.hasActivity || (activeSkin==nil ? titleMarquee.needsAnimation || artistMarquee.needsAnimation:skinMarquee.needsAnimation)}
    private var animationVisible:Bool {window?.isVisible==true && window?.isMiniaturized==false && window?.occlusionState.contains(.visible)==true && !NSApp.isHidden}
    private func stopDisplayTimer() {spectrumTimer?.invalidate();spectrumTimer=nil}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in animationObservers {NotificationCenter.default.removeObserver(observer)};animationObservers=[]
        for name in [NSWindow.didChangeOcclusionStateNotification,NSWindow.didDeminiaturizeNotification,NSWindow.didMiniaturizeNotification] {
            animationObservers.append(NotificationCenter.default.addObserver(forName:name,object:window,queue:.main) {[weak self] _ in
                MainActor.assumeIsolated {guard let self else {return};if self.animationVisible && self.needsAnimation {self.startDisplayTimer()}else {self.stopDisplayTimer()}}
            })
        }
        if animationVisible && needsAnimation {startDisplayTimer()}else {stopDisplayTimer()}
    }
    private var titleDisplayRect:NSRect {activeSkin==nil ? NSRect(x:136,y:25,width:209,height:36):skinRect(NSRect(x:111,y:22,width:152,height:15))}
    private var spectrumDisplayRect:NSRect {activeSkin==nil ? NSRect(x:18,y:69,width:100,height:24):skinRect(NSRect(x:24,y:43,width:74,height:18))}
    func startDisplayTimer() {
        guard animationVisible else {stopDisplayTimer();return}
        let interval=1/visualizerSettings.fps
        if spectrumTimer?.isValid==true,spectrumTimer?.timeInterval==interval {return}
        stopDisplayTimer();lastAnimationTime=ProcessInfo.processInfo.systemUptime
        let timer=Timer(timeInterval:interval,repeats:true) {[weak self] _ in
            guard let self else {return}
            guard self.animationVisible,self.needsAnimation else {self.stopDisplayTimer();return}
            let now=ProcessInfo.processInfo.systemUptime,delta=min(0.2,max(0,now-self.lastAnimationTime));self.lastAnimationTime=now
            self.spectrumDynamics.step(input:self.spectrumInput,playing:self.isPlaying,delta:delta,settings:self.visualizerSettings)
            self.spectrum=self.spectrumDynamics.levels;self.peaks=self.spectrumDynamics.peaks
            for marquee in [self.titleMarquee,self.artistMarquee,self.skinMarquee] {marquee.advance(delta)}
            self.setNeedsDisplay(self.spectrumDisplayRect)
            if self.titleMarquee.needsAnimation || self.artistMarquee.needsAnimation || self.skinMarquee.needsAnimation{self.setNeedsDisplay(self.titleDisplayRect)}
        }
        timer.tolerance=interval/5;spectrumTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func applyVisualizer(_ settings:VisualizerSettings) {let old=visualizerSettings.fps;visualizerSettings=settings;if old != settings.fps {startDisplayTimer()}}
    @discardableResult func addButton(_ title:String,_ frame:NSRect,_ command:String)->NSButton {
        let button=MetalButton(frame:frame);button.skinRole=command;defaultFrames[command]=frame;button.title=title;button.identifier=NSUserInterfaceItemIdentifier(command);button.target=self;button.action=#selector(buttonPressed);button.isBordered=false;button.setAccessibilityLabel(command=="connect" ? "Увійти через Google" : command=="openFiles" ? "Відкрити локальні аудіофайли" : title);addSubview(button);return button
    }
    func arrangeModules() {
        _=playlistView;onModules?();needsDisplay=true
        for b in subviews.compactMap({$0 as? MetalButton}) {b.skinSelected=b.identifier?.rawValue=="toggleEQ" ? eqVisible : b.identifier?.rawValue=="togglePlaylist" ? playlistVisible : b.skinSelected;b.needsDisplay=true}
    }
    func applySkinLayout() {
        let positions:[String:NSRect]=[
            "previous":NSRect(x:16,y:88,width:23,height:18),"play":NSRect(x:39,y:88,width:23,height:18),"pause":NSRect(x:62,y:88,width:23,height:18),"stop":NSRect(x:85,y:88,width:23,height:18),"next":NSRect(x:108,y:88,width:22,height:18),"openFiles":NSRect(x:136,y:89,width:22,height:16),"shuffle":NSRect(x:164,y:89,width:47,height:15),"repeat":NSRect(x:210,y:89,width:28,height:15),"toggleEQ":NSRect(x:219,y:58,width:23,height:12),"togglePlaylist":NSRect(x:242,y:58,width:23,height:12),"pin":NSRect(x:254,y:3,width:9,height:9),"minimize":NSRect(x:244,y:3,width:9,height:9),"close":NSRect(x:264,y:3,width:9,height:9)]
        for b in subviews.compactMap({$0 as? MetalButton}) {if let key=b.identifier?.rawValue {b.frame=activeSkin==nil ? (defaultFrames[key] ?? b.frame) : positions[key].map {skinRect($0)} ?? b.frame;b.needsDisplay=true}}
        if let video=subviews.compactMap({$0 as? MetalButton}).first(where:{$0.identifier?.rawValue=="toggleVideo"}),activeSkin != nil {video.frame=skinRect(NSRect(x:177,y:58,width:38,height:12))}
        volume.frame=activeSkin==nil ? NSRect(x:174,y:78,width:75,height:16) : skinRect(NSRect(x:107,y:57,width:68,height:13))
        seek.frame=activeSkin==nil ? NSRect(x:12,y:100,width:333,height:12) : skinRect(NSRect(x:16,y:72,width:248,height:10))
        clockControl.frame=activeSkin==nil ? NSRect(x:30,y:28,width:95,height:35) : skinRect(NSRect(x:39,y:23,width:63,height:18))
        spectrumControl.frame=activeSkin==nil ? NSRect(x:16,y:66,width:109,height:30) : skinRect(NSRect(x:23,y:42,width:77,height:20))
        transportIndicator.frame=activeSkin==nil ? NSRect(x:17,y:35,width:10,height:10) : skinRect(NSRect(x:24,y:28,width:9,height:9))
        updateDisplayAccessibility()
        equalizerView.applySkinLayout();playlistView.needsDisplay=true;needsDisplay=true
    }
    func skinRect(_ r:NSRect)->NSRect {NSRect(x:r.minX*360/275,y:r.minY*146/116,width:r.width*360/275,height:r.height*146/116)}
    func resetMarquees() {for marquee in [titleMarquee,artistMarquee,skinMarquee] {marquee.reset()}}
    func updateClock(time:Double,duration:Double) {
        elapsed=time.isFinite ? max(0,time) : 0;self.duration=duration.isFinite ? max(0,duration) : 0
        let value=remainingTime ? max(0,self.duration-elapsed) : elapsed
        let oldClock=clock
        let seconds=Int(min(value,Double(Int.max/2)).rounded(.down));clock=(remainingTime ? "−" : "")+String(format:"%02d:%02d",seconds/60,seconds%60)
        if oldClock != clock{updateDisplayAccessibility();setNeedsDisplay(activeSkin==nil ? NSRect(x:12,y:25,width:116,height:43):skinRect(NSRect(x:36,y:24,width:68,height:20)))}
    }
    func updateDisplayAccessibility() {
        clockControl.setAccessibilityValue((remainingTime ? "Залишилось " : "Минуло ")+clock)
        spectrumControl.setAccessibilityValue(wideSpectrum ? "Широкі смуги" : "Вузькі смуги")
    }
    @objc func toggleClock() {remainingTime.toggle();UserDefaults.standard.set(remainingTime,forKey:"display.remainingTime");updateClock(time:elapsed,duration:duration)}
    @objc func toggleSpectrum() {wideSpectrum.toggle();UserDefaults.standard.set(wideSpectrum,forKey:"display.wideSpectrum");updateDisplayAccessibility();needsDisplay=true}
    func spectrumColumns()->[(level:Float,peak:Float)] {
        let count=wideSpectrum ? 19 : 37
        return (0..<count).map {i in
            let start=i*37/count,end=(i+1)*37/count
            return (spectrum[start..<end].max() ?? 0,peaks[start..<end].max() ?? 0)
        }
    }
    func drawSpectrum(in rect:NSRect,skin:WSZSkin?=nil) {
        let columns=spectrumColumns(),step=rect.width/CGFloat(columns.count),barWidth=max(1,step-1),rowStep=rect.height/9
        for (col,values) in columns.enumerated() {
            let level=min(9,max(0,Int(values.level*9))),peak=min(8,max(0,Int(values.peak*8)))
            for row in 0..<9 {
                let color:NSColor
                if 8-row>=level {color=NSColor(calibratedWhite:0.04,alpha:1)}
                else {
                    let height=8-row,position=level<=1 ? 0 : Float(height)/Float(level-1)
                    if let skin,skin.spectrumColors.count>=18 {color=skin.spectrumColors[min(17,2+Int((1-position)*15))]}
                    else {color=position>=0.8 ? NSColor(calibratedRed:1,green:0.47,blue:0.10,alpha:1) : position>=0.45 ? NSColor(calibratedRed:1,green:0.87,blue:0.19,alpha:1) : green}
                }
                fill(NSRect(x:rect.minX+CGFloat(col)*step,y:rect.minY+CGFloat(row)*rowStep,width:barWidth,height:max(1,rowStep-0.7)),color)
            }
            if values.peak>0.03 {fill(NSRect(x:rect.minX+CGFloat(col)*step,y:rect.minY+CGFloat(8-peak)*rowStep,width:barWidth,height:1),skin?.textColor ?? NSColor(calibratedRed:1,green:0.80,blue:0.35,alpha:1))}
        }
    }
    @objc func buttonPressed(_ sender:NSButton) {onAction?(sender.identifier?.rawValue ?? "")}
    @objc func volumeChanged() {onAction?("volume")}
    @objc func seekChanged() {onAction?("seek")}
    @objc func search() {onAction?("search")}
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) ? .copy : []
    }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        guard let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty else {return false}
        onFiles?(urls);return true
    }
    override func mouseDown(with event:NSEvent) {if convert(event.locationInWindow,from:nil).y<20 {if let w=window as? RetroWindow,let group=w.group {group.dragPlayer(with:event)} else {window?.performDrag(with:event)}}}
    override func draw(_ dirtyRect:NSRect) {
        defer {if animationVisible && needsAnimation {startDisplayTimer()}}
        fill(bounds,NSColor(calibratedWhite:0.025,alpha:1))
        if let skin=activeSkin {drawSkin(skin);return}
        panel(NSRect(x:0,y:0,width:360,height:146),diagnosticBuild ? "TEST / MUTED" : "RETROAMP")
        
        let screen=NSRect(x:12,y:25,width:116,height:72);fill(screen,NSColor(calibratedRed:0.01,green:0.025,blue:0.017,alpha:1));bevel(screen,recessed:true)
        NSGraphicsContext.saveGraphicsState();let transform=NSAffineTransform();transform.translateX(by:clock.hasPrefix("−") ? 29 : 31,yBy:32);transform.scale(by:clock.hasPrefix("−") ? 0.56 : 0.60);transform.concat();drawClockRaw(clock,origin:.zero);NSGraphicsContext.restoreGraphicsState()
        drawTransportIndicator(in:NSRect(x:17,y:35,width:10,height:10))
        drawSpectrum(in:NSRect(x:18,y:69,width:100,height:24))
        fill(NSRect(x:136,y:25,width:209,height:36),.black);bevel(NSRect(x:136,y:25,width:209,height:36),recessed:true)
        titleMarquee.draw(titleLine,in:NSRect(x:142,y:29,width:197,height:14),size:10,color:green)
        artistMarquee.draw(artistLine,in:NSRect(x:142,y:45,width:197,height:12),size:8,color:dimGreen)
        text(formatLine,NSRect(x:137,y:65,width:143,height:11),size:8,color:.lightGray)
        text(transportState.label,NSRect(x:295,y:65,width:54,height:11),size:8,color:transportState == .playing ? green : .lightGray)
        text("VOL",NSRect(x:138,y:81,width:27,height:11),size:8,color:.lightGray)
        
    }
    func drawSkin(_ skin:WSZSkin) {
        skin.drawMain(in:NSRect(x:0,y:0,width:360,height:146),selected:window?.isKeyWindow==true)
        skin.draw("balance",NSRect(x:9,y:14*15,width:38,height:13),skinRect(NSRect(x:177,y:57,width:38,height:13)))
        skin.draw("balance",NSRect(x:15,y:422,width:14,height:11),skinRect(NSRect(x:189,y:58,width:14,height:11)))
        let digits=Array(clock.filter(\.isNumber).suffix(4))
        for (i,c) in digits.enumerated() {if let d=c.wholeNumberValue {let target=skinRect(NSRect(x:CGFloat([48,59,78,89][i]),y:26,width:9,height:13));if !skin.draw("numbers",NSRect(x:CGFloat(d)*9,y:0,width:9,height:13),target) {text(String(c),target,size:14,color:skin.textColor)}}}
        let minus=skinRect(NSRect(x:39,y:31,width:6,height:1));fill(minus,clock.hasPrefix("−") ? skin.textColor : (skin.pixelColor("main",x:40,y:26) ?? .black))
        skinMarquee.draw(titleLine+" • "+artistLine,in:skinRect(NSRect(x:112,y:23,width:151,height:13)),size:10,color:skin.textColor)
        fill(skinRect(NSRect(x:111,y:42,width:91,height:12)),skin.pixelColor("main",x:114,y:25) ?? .black);text(formatLine,skinRect(NSRect(x:111,y:43,width:91,height:10)),size:7,color:skin.textColor)
        _=skin.draw("playpaus",NSRect(x:transportState == .playing ? 0 : transportState == .paused ? 9 : 18,y:0,width:9,height:9),skinRect(NSRect(x:24,y:28,width:9,height:9)))
        _=skin.draw("monoster",NSRect(x:0,y:isPlaying ? 0 : 12,width:29,height:12),skinRect(NSRect(x:212,y:41,width:29,height:12)))
        drawSpectrum(in:skinRect(NSRect(x:24,y:43,width:74,height:18)),skin:skin)
    }
    func panel(_ rect:NSRect,_ title:String) {
        fill(rect,graphite);bevel(rect)
        let heading=title.uppercased()
        let titleWidth=min(228,CGFloat(heading.count)*6+8),left=(360-titleWidth)/2
        for y in [7.0,10.0] {fill(NSRect(x:10,y:rect.minY+y,width:max(0,left-15),height:1),NSColor(calibratedRed:0.80,green:0.75,blue:0.51,alpha:1));fill(NSRect(x:left+titleWidth+5,y:rect.minY+y,width:max(0,347-left-titleWidth),height:1),NSColor(calibratedRed:0.80,green:0.75,blue:0.51,alpha:1))}
        text(heading,NSRect(x:left,y:rect.minY+3,width:titleWidth,height:14),size:9,color:.lightGray,bold:true)
    }
    func drawClockRaw(_ string:String,origin:NSPoint) {
        let digits:[Character:[Int]]=["0":[0,1,2,3,4,5],"1":[1,2],"2":[0,1,6,4,3],"3":[0,1,2,3,6],"4":[5,6,1,2],"5":[0,5,6,2,3],"6":[0,5,4,3,2,6],"7":[0,1,2],"8":[0,1,2,3,4,5,6],"9":[0,1,2,3,5,6]]
        var x=origin.x
        for char in string {
            if char=="−" {fill(NSRect(x:x,y:origin.y+22,width:14,height:3),green);x+=18;continue}
            if char==":" {fill(NSRect(x:x+1,y:origin.y+13,width:4,height:4),green);fill(NSRect(x:x+1,y:origin.y+29,width:4,height:4),green);x+=10;continue}
            let segs=[NSRect(x:x+4,y:origin.y,width:17,height:3),NSRect(x:x+22,y:origin.y+4,width:3,height:17),NSRect(x:x+22,y:origin.y+25,width:3,height:17),NSRect(x:x+4,y:origin.y+43,width:17,height:3),NSRect(x:x,y:origin.y+25,width:3,height:17),NSRect(x:x,y:origin.y+4,width:3,height:17),NSRect(x:x+4,y:origin.y+22,width:17,height:3)]
            for index in 0..<7 {fill(segs[index],digits[char]?.contains(index)==true ? green : NSColor(calibratedRed:0.07,green:0.12,blue:0.045,alpha:1))};x+=30
        }
    }
}


final class RetroWindow:NSWindow {
    weak var group:WindowGroup?
    override func sendEvent(_ event:NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {group?.endPlayerDrag();group?.bringForward(self)}
        super.sendEvent(event)
    }
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
}

final class ConnectionPanel:NSPanel {
    let restore=NSButton(title:"Відновити збережений вхід",target:nil,action:nil)
    let google=NSButton(title:"Увійти через Google",target:nil,action:nil)
    let cancel=NSButton(title:"Скасувати",target:nil,action:nil)
    let message=NSTextField(wrappingLabelWithString:"Відкриється окреме вікно Google. Увійдіть у свій акаунт — бібліотека підключиться автоматично.")
    var submitted:(()->Void)?
    var cancelled:(()->Void)?
    var restored:(()->Void)?
    init() {
        super.init(contentRect:NSRect(x:0,y:0,width:360,height:214),styleMask:[.titled],backing:.buffered,defer:false)
        title="YouTube Music · Google"
        guard let content=contentView else {return}
        message.stringValue="Збережений вхід відновлюється без браузера. Після оновлення macOS може попросити доступ до Keychain. Для іншого акаунта натисніть «Увійти через Google»."
        message.frame=NSRect(x:20,y:122,width:320,height:72);message.font = drawingFont(size:11,bold:false);content.addSubview(message)
        restore.frame=NSRect(x:20,y:80,width:320,height:32);restore.font=drawingFont(size:10,bold:false);restore.bezelStyle = .rounded;restore.target=self;restore.action=#selector(restoreSaved);content.addSubview(restore)
        google.frame=NSRect(x:20,y:40,width:212,height:32);google.font=drawingFont(size:10,bold:false);google.bezelStyle = .rounded;google.target=self;google.action=#selector(submit);content.addSubview(google)
        cancel.frame=NSRect(x:242,y:40,width:98,height:32);cancel.font=drawingFont(size:10,bold:false);cancel.bezelStyle = .rounded;cancel.target=self;cancel.action=#selector(closeSheet);content.addSubview(cancel)
        let privacy=NSTextField(labelWithString:"Пароль вводиться на сторінці Google.");privacy.frame=NSRect(x:20,y:14,width:320,height:16);privacy.font = drawingFont(size:9,bold:false);privacy.textColor = .secondaryLabelColor;content.addSubview(privacy)
    }
    @objc func submit() {submitted?()}
    @objc func restoreSaved() {restored?()}
    @objc func closeSheet() {cancelled?()}
}

@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate,NSTableViewDataSource,NSTableViewDelegate {
    let library=LibraryStore()
    let mediaControls=MediaControls()
    var settingsWindow:SettingsWindow?
    var importTask:Task<Void,Never>?
    var favoriteTask:Task<Void,Never>?
    let windowGroup=WindowGroup()
    var window:RetroWindow!
    var equalizerWindow:RetroWindow!
    var playlistWindow:RetroWindow!
    var videoWindow:RetroWindow!
    let videoPanel=VideoPanel(frame:NSRect(x:0,y:0,width:480,height:318))
    var videoVisible=UserDefaults.standard.bool(forKey:"video.visible")
    var skinTask:Task<Void,Never>?
    let view=RetroView(frame:NSRect(x:0,y:0,width:360,height:166))
    let service=MusicService()
    let engine=MusicEngine()
    var credentials:SessionCredentials?
    var items:[MusicItem]=[]
    var queue:[MusicItem]=[]
    var queueIndex = -1
    var current:MusicItem?
    var continuation:String?
    var endpoint="search"
    var requestGeneration=0
    var requestTask:Task<Void,Never>?
    var authTask:Task<Void,Never>?
    var startupTask:Task<Void,Never>?
    var sessionGeneration=0
    var installingSession=false
    var connection:ConnectionPanel?
    let googleLogin=GoogleLogin()
    var lastState:PlaybackState?
    var repeatMode=0
    var shuffleEnabled=false
    var orderedQueue:[MusicItem]=[]
    var previousRewind:(id:String,until:Double)?
    var transportIntent=TransportState.idle
    var muted=false
    var endHandled=false
    var renderPath:String?
    var verificationPath:String?
    var verificationStage=0
    var finishingVerification=false
    var adTestStage=0
    var adTestTime:Double=0
    var adTestDuration:Double=0
    var verification:[String:Any]=[:]
    var pendingFileURLs:[URL]=[]
    var requestedPlaybackAt=Date()
    var eventMonitor:Any?
    var statusHoldUntil=Date.distantPast
    func applicationDidFinishLaunching(_ notification:Notification) {
        setUpMenu()
        makeWindows()
        windowGroup.onPinChange={ [weak self] enabled in self?.updatePinButton(enabled) }
        updatePinButton(windowGroup.alwaysOnTop)
        view.table.dataSource=self;view.table.delegate=self;view.table.target=self;view.table.doubleAction=#selector(activateSelection)
        view.onAction={ [weak self] action in self?.act(action) }
        view.updateModes(shuffle:shuffleEnabled,repeatMode:repeatMode)
        updateFavoriteButton()
        view.onFiles={ [weak self] urls in self?.importFiles(urls) }
        engine.onState={ [weak self] state in self?.receive(state) }
        engine.onProgress={ [weak self] message in self?.status(message) }
        engine.onError={ [weak self] error in self?.status(error);self?.view.updateTransport(.failed);self?.view.hasSource=false;self?.mediaControls.clear();if let self,self.verificationPath != nil {
            if self.verificationStage==8 {self.verification["expectedTransportError"]=true;self.verificationStage=9;self.engine.resume()} else {self.verification["engineError"]=error}
        } }
        engine.onSpectrum={ [weak self] levels in guard let self,levels.count==37 else {return};self.view.spectrumInput=levels
            if self.verificationPath != nil,(levels.max() ?? 0)>0.02 {
                self.verification["spectrumNonzeroFrames"]=(self.verification["spectrumNonzeroFrames"] as? Int ?? 0)+1
                self.verification["spectrumPeak"]=max(self.verification["spectrumPeak"] as? Float ?? 0,levels.max() ?? 0)
            } }
        view.onModules={ [weak self] in self?.showModules() }
        videoPanel.onClose={ [weak self] in self?.setVideoVisible(false) }
        videoPanel.canvas.onToggle={ [weak self] in self?.act("togglePlayback") }
        engine.videoOutput.onFrame={ [weak self] image in self?.videoPanel.canvas.image=image }
        engine.videoOutput.onError={ [weak self] message in self?.videoPanel.canvas.message=message }
        engine.resolveVideoRendition={ [service] id in try await service.videoRendition(id) }
        videoPanel.onQuality={ [weak self] quality in self?.engine.videoQuality=quality;quality.save() }
        engine.onVideoQuality={ [weak self] state in self?.videoPanel.showQuality(state) }
        engine.onVideoMessage={ [weak self] message in self?.videoPanel.canvas.message=message }
        engine.videoVisible=videoVisible;updateVideoButton()
        mediaControls.onAction={ [weak self] action in self?.handleMediaAction(action) ?? false }
        view.equalizerView.onClose={ [weak self] in self?.act("toggleEQ") }
        view.equalizerView.onChange={ [weak self] settings in self?.engine.equalizerSettings(settings) }
        engine.equalizerSettings(view.equalizerView.settings);engine.volume(view.volume.value);if CommandLine.arguments.contains("--quiet") {engine.mute(true)}
        showModules();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        if diagnosticBuild,CommandLine.arguments.contains(where:{$0.hasPrefix("--check-")}) {for w in windowGroup.windows {w.ignoresMouseEvents=true}}
        eventMonitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self else {return event}
            if let action=self.transportKeyAction(event) {self.act(action);return nil}
            return event
        }
        if let path=argument("--verify-local"),let input=argument("--local-directory") {
            verificationPath=path;engine.mute(true)
            let urls=(try? FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:input),includingPropertiesForKeys:nil))?.sorted { $0.lastPathComponent<$1.lastPathComponent } ?? []
            importFiles(urls,autoplay:false)
            Task { @MainActor in
                await importTask?.value
                verification["localImportedCount"]=items.count
                verification["localAllPlayable"]=items.allSatisfy(\.isPlayable)
                if let item=items.first {queue=items;queueIndex=0;play(item)}
                DispatchQueue.main.asyncAfter(deadline:.now()+25) {self.finishLocalVerification()}
            }
            return
        }
        if let path=argument("--check-native-stream"),let input=argument("--video-fixture"){Task{@MainActor in await checkNativeStream(path,fixture:URL(fileURLWithPath:input))};return}
        if let path=argument("--check-v09") {Task { @MainActor in await checkV09(path)};return}
        if let path=argument("--check-session-storage") {Task { @MainActor in await checkSessionStorage(path)};return}
        if let path=argument("--check-cold-stream") {Task { @MainActor in await checkColdStream(path)};return}
        if let path=argument("--check-resource-lifecycle") {Task { @MainActor in await checkResourceLifecycle(path)};return}
        if let path=argument("--check-resources") {Task { @MainActor in await checkResources(path)};return}
        if let path=argument("--check-public-hd") {Task { @MainActor in await checkPublicHD(path)};return}
        if let path=argument("--check-video-quality"),let fixture=argument("--video-fixture"),let audio=argument("--audio-fixture") {Task { @MainActor in await checkVideoQuality(path,fixture:URL(fileURLWithPath:fixture),audio:URL(fileURLWithPath:audio))};return}
        if let path=argument("--check-video"),let fixture=argument("--video-fixture") {Task { @MainActor in await checkVideo(path,fixture:URL(fileURLWithPath:fixture))};return}
        if let path=argument("--check-public-video") {Task { @MainActor in await checkPublicVideo(path)};return}
        if let path=argument("--check-transport") {Task { @MainActor in await checkTransport(path)};return}
        if let path=argument("--check-display") {checkDisplay(path);return}
        if let path=argument("--check-group") {DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {self.checkWindowGroup(path)};return}
        if let path=argument("--check-windows") {DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {self.checkWindows(path)};return}
        if let path=argument("--check-skin"),let input=argument("--skin-file") {checkSkin(path,input:input);return}
        if let path=argument("--check-login") {
            Task { @MainActor in
                do {let result=try await googleLogin.checkBrowser();let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:path))} catch {let data=try? JSONSerialization.data(withJSONObject:["passed":false,"error":error.localizedDescription]);try? data?.write(to:URL(fileURLWithPath:path))}
                NSApp.terminate(nil)
            }
            return
        }
        if let path=argument("--check-render") {
            Task { @MainActor in
                var result:[String:Any]=["passed":true]
                for appearance in [NSAppearance.Name.aqua,.darkAqua] {
                    for panel in [view as NSView,view.equalizerView,view.playlistView] {panel.appearance=NSAppearance(named:appearance);for _ in 0..<250 {panel.needsDisplay=true;panel.displayIfNeeded()}}
                }
                result["nativeWindowCount"]=3;result["redraws"]=1500
                let data=try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);try! data.write(to:URL(fileURLWithPath:path));NSApp.terminate(nil)
            }
            return
        }
        if let path=argument("--check-local-audio"),let input=argument("--local-directory") {
            Task { @MainActor in
                do {let result=try await checkLocalAudio(directory:URL(fileURLWithPath:input));let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:path))} catch {let data=try? JSONSerialization.data(withJSONObject:["passed":false,"error":error.localizedDescription]);try? data?.write(to:URL(fileURLWithPath:path))}
                NSApp.terminate(nil)
            };return
        }
        if let path=argument("--check-audio") {
            Task { @MainActor in
                do {let result=try await engine.checkAudio();let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:path))} catch {try? "{\"passed\":false}".write(toFile:path,atomically:true,encoding:.utf8)}
                NSApp.terminate(nil)
            };return
        }
        if let path=argument("--check-ui") {checkUI(path);return}
        if let path=argument("--render") {saveRender(path);NSApp.terminate(nil);return}
        if CommandLine.arguments.contains("--ui-preview") {updateFavoriteButton();return}
        if let path=argument("--verify") {
            verificationPath=path;engine.mute(true);status("ПЕРЕВІРКА ПОШУКУ ТА ВІДТВОРЕННЯ…")
            Task { @MainActor in
                do {
                    let page=try await service.search("Daft Punk")
                    verification["searchResults"]=page.items.count
                    verification["searchContainsGetLucky"]=page.items.contains {$0.title.contains("Get Lucky")}
                    setPage(page,title:"SEARCH RESULTS",endpoint:"search")
                    let id=argument("--video-id") ?? "4D7u5KF7SP8"
                    let track=MusicItem(id:id,title:page.items.first(where:{$0.videoID==id})?.title ?? "Перевірка аудіо",subtitle:"Тихе відтворення",videoID:id,browseID:nil,duration:"")
                    if CommandLine.arguments.contains("--with-session-fixture") {
                        let fixture=SessionCredentials(cookie:"SAPISID=synthetic-invalid-session; SID=synthetic-invalid-sid",authUser:"0",pageID:nil)
                        await engine.installSession(fixture);verification["sessionFixtureAttached"]=true
                    }
                    if let input=argument("--local-switch-file") {
                        engine.playLocal(URL(fileURLWithPath:input));try await Task.sleep(nanoseconds:300_000_000)
                        verification["localToYouTubeSwitchRequested"]=engine.isLocal
                    }
                    queue=[track];queueIndex=0;play(track);engine.stop();engine.resume()
                    if CommandLine.arguments.contains("--verify-race") {
                        let final=MusicItem(id:"4D7u5KF7SP8",title:"Get Lucky",subtitle:"Daft Punk",videoID:"4D7u5KF7SP8",browseID:nil,duration:"")
                        for (delay,item) in [(0.4,final),(0.45,track),(0.5,final)] {DispatchQueue.main.asyncAfter(deadline:.now()+delay) {self.play(item)}}
                    }
                    DispatchQueue.main.asyncAfter(deadline:.now()+(CommandLine.arguments.contains("--verify-lifecycle") ? 180 : 100)) {self.finishVerification()}
                } catch {verification["error"]=error.localizedDescription;finishVerification()}
            }
            return
        }
        if !library.tracks.isEmpty {queue=library.tracks;setPage(MusicPage(items:queue,continuation:nil),title:"LOCAL FILES",endpoint:"local");status("ВІДНОВЛЕНО \(queue.count) ЛОКАЛЬНИХ ФАЙЛІВ")}
        let explicitStartupSkin=pendingFileURLs.contains {$0.pathExtension.lowercased()=="wsz"}
        if !pendingFileURLs.isEmpty {let urls=pendingFileURLs;pendingFileURLs=[];importFiles(urls)}
        if let path=argument("--skin") {loadSkin(URL(fileURLWithPath:path),persist:false)} else if !explicitStartupSkin {let url=skinStorageURL;if FileManager.default.fileExists(atPath:url.path) {loadSkin(url,persist:false)}}
        var storedCredentials:SessionCredentials?
        do {storedCredentials=try KeychainSession.load();if storedCredentials != nil,storedCredentials?.browserCookies==nil {status("ОНОВІТЬ ВХІД ЧЕРЕЗ GOOGLE")}} catch {status(error.localizedDescription)}
        if let credentials=storedCredentials,credentials.browserCookies != nil {
            status("ПЕРЕВІРЯЮ ЗБЕРЕЖЕНУ СЕСІЮ…")
            sessionGeneration+=1;let generation=sessionGeneration
            startupTask=Task { @MainActor in
                do {
                    let page=try await service.authenticate(credentials)
                    guard !Task.isCancelled,generation==sessionGeneration else {return}
                    installingSession=true;requestGeneration+=1;requestTask?.cancel();await service.setSession(credentials)
                    guard !Task.isCancelled,generation==sessionGeneration else {return}
                    await engine.installSession(credentials,preserveLocal:true)
                    guard !Task.isCancelled,generation==sessionGeneration else {return}
                    self.credentials=credentials;installingSession=false
                    if let active=current {if let id=active.videoID {engine.play(id)}} else if library.tracks.isEmpty {resetPlaybackDisplay();setPage(page,title:"MY PLAYLISTS",endpoint:"browse");status("СЕСІЮ ПІДКЛЮЧЕНО • YOUTUBE MUSIC")} else {status("GOOGLE ПІДКЛЮЧЕНО • ЛОКАЛЬНІ ФАЙЛИ ЗБЕРЕЖЕНО")}
                } catch {if !Task.isCancelled,generation==sessionGeneration {self.credentials=nil;installingSession=false;status(error.localizedDescription)}}
            }
        }
    }
    func argument(_ name:String)->String? {guard let i=CommandLine.arguments.firstIndex(of:name),CommandLine.arguments.indices.contains(i+1) else {return nil};return CommandLine.arguments[i+1]}
    func setUpMenu() {
        let menu=NSMenu();let appItem=NSMenuItem();menu.addItem(appItem)
        let appMenu=NSMenu();let settings=NSMenuItem(title:"Налаштування…",action:#selector(showSettings),keyEquivalent:",");settings.target=self;appMenu.addItem(settings);appMenu.addItem(.separator());appMenu.addItem(NSMenuItem(title:"Завершити Retroamp",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"));appItem.submenu=appMenu
        let fileItem=NSMenuItem();fileItem.title="Файл";let fileMenu=NSMenu(title:"Файл")
        let open=NSMenuItem(title:"Додати аудіофайли або папки…",action:#selector(openLocalFiles),keyEquivalent:"o");open.target=self;fileMenu.addItem(open)
        let folder=NSMenuItem(title:"Додати папку з альбомами…",action:#selector(openLocalFolder),keyEquivalent:"O");folder.target=self;fileMenu.addItem(folder)
        let more=NSMenuItem(title:"Завантажити ще з YouTube Music",action:#selector(loadMore),keyEquivalent:"");more.target=self;fileMenu.addItem(more);fileItem.submenu=fileMenu;menu.addItem(fileItem)
        let editItem=NSMenuItem();editItem.title="Редагування";let edit=NSMenu();edit.addItem(NSMenuItem(title:"Вирізати",action:#selector(NSText.cut(_:)),keyEquivalent:"x"));edit.addItem(NSMenuItem(title:"Копіювати",action:#selector(NSText.copy(_:)),keyEquivalent:"c"));edit.addItem(NSMenuItem(title:"Вставити",action:#selector(NSText.paste(_:)),keyEquivalent:"v"));edit.addItem(NSMenuItem(title:"Вибрати все",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a"));editItem.submenu=edit;menu.addItem(editItem);addAppearanceMenu(to:menu)
        let windowsItem=NSMenuItem();windowsItem.title="Вікно";let windowsMenu=NSMenu(title:"Вікно")
        for (title,selector,key) in [("Плеєр",#selector(focusPlayer),"1"),("Еквалайзер",#selector(focusEqualizer),"2"),("Плейлист",#selector(focusPlaylist),"3"),("VIDEO",#selector(focusVideo),"4")] {let item=NSMenuItem(title:title,action:selector,keyEquivalent:key);item.target=self;windowsMenu.addItem(item)}
        windowsItem.submenu=windowsMenu;menu.addItem(windowsItem);NSApp.mainMenu=menu
    }
    func numberOfRows(in tableView:NSTableView)->Int {view.rows.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let label=NSTextField(labelWithString:String(format:"%02d. %@",row+1,view.rows[row]));label.font=drawingFont(size:10,bold:false);label.textColor=activeSkin?.textColor ?? green;label.lineBreakMode = .byTruncatingTail;label.toolTip=view.rows[row];return label
    }
    func tableView(_ tableView:NSTableView,rowViewForRow row:Int)->NSTableRowView? {RetroRow()}
    func tableViewSelectionDidChange(_ notification:Notification) {
        for row in 0..<table.numberOfRows {if let label=table.view(atColumn:0,row:row,makeIfNecessary:false) as? NSTextField {label.textColor=table.selectedRow==row ? .white : (activeSkin?.textColor ?? green)}}
    }
    var table:NSTableView {view.table}
    func status(_ text:String,holdFor:Double=3) {statusHoldUntil=Date().addingTimeInterval(holdFor);view.status=text;view.needsDisplay=true}
    func setPage(_ page:MusicPage,title:String,endpoint:String,append:Bool=false) {
        if append {let old=Set(items.map(\.id));items+=page.items.filter {!old.contains($0.id)}} else {items=page.items}
        continuation=page.continuation;self.endpoint=endpoint;view.sectionTitle=title;view.rows=items.map {!$0.isPlayable ? "▸ "+$0.line : $0.line};view.needsDisplay=true
    }
    @objc func activateSelection() {
        guard !installingSession else {status("ПІДКЛЮЧАЮ СЕСІЮ…");return}
        let index=view.table.selectedRow
        guard items.indices.contains(index) else {return}
        let item=items[index]
        if item.isPlayable {configureQueue(items.filter { $0.isPlayable },starting:item);play(item)}
        else if let browseID=item.browseID {loadBrowse(browseID,title:item.title)}
    }
    func play(_ item:MusicItem) {
        guard !streamTerminating,!installingSession else{return}
        guard item.isPlayable else {return}
        previousRewind=nil;transportIntent = .playing;view.hasSource=false;view.updateTransport(.loading)
        view.resetMarquees();view.spectrumDynamics.reset();view.spectrumInput=Array(repeating:0,count:37);current=item;updateVideoTrack();updateFavoriteButton();mediaControls.clear();endHandled=false;lastState=nil;requestedPlaybackAt=Date();view.titleLine=item.title;view.artistLine=item.subtitle;view.updateClock(time:0,duration:0);view.seek.value=0;view.durationLine="";view.needsDisplay=true;view.formatLine=item.localURL==nil ? "STREAM / STEREO" : "LOCAL / "+(item.localURL?.pathExtension.uppercased() ?? "AUDIO");status("ВІДКРИВАЮ АУДІО…");if let url=item.localURL {engine.playLocal(url)} else if let id=item.videoID {engine.play(id)}
    }
    func refreshMediaCommands() {mediaControls.update(item:current,state:lastState,canNext:queueIndex+1<queue.count || repeatMode==1,canPrevious:lastState?.ad != true)}
    func receive(_ state:PlaybackState) {
        guard !installingSession,!finishingVerification else {return}
        let unchanged=lastState==state
        lastState=state;refreshMediaCommands()
        guard !unchanged else {return}
        videoPanel.caption.stringValue=(current?.title ?? "VIDEO")+" · "+format(state.time)+" · "+(state.paused ? "PAUSE" : "PLAY")
        view.hasSource=state.hasSource
        if state.hasSource {view.updateTransport(state.ended || transportIntent == .stopped ? .stopped : state.paused ? .paused : .playing)}
        else if view.transportState != .failed {view.updateTransport(current==nil ? .idle : transportIntent == .paused ? .paused : transportIntent == .stopped ? .stopped : .loading)}
        view.updateClock(time:state.time,duration:state.duration);view.durationLine=state.duration>0 ? format(state.duration) : "";view.seek.value=state.duration>0 ? min(1,state.time/state.duration) : 0
        if state.ad {view.titleLine="РЕКЛАМА • YOUTUBE MUSIC";view.artistLine="Відтворення продовжиться після реклами."}
        else {view.titleLine=state.title.isEmpty ? (current?.title ?? "YOUTUBE MUSIC") : state.title;view.artistLine=state.artist.isEmpty ? (current?.subtitle ?? "") : state.artist}
        if !state.error.isEmpty {status(state.error)} else if state.hasSource,Date()>=statusHoldUntil {status(state.ad ? "РЕКЛАМА" : (state.paused ? "ПАУЗА • " : "ВІДТВОРЕННЯ • ")+(current?.localURL==nil ? "YOUTUBE MUSIC" : "ЛОКАЛЬНИЙ ФАЙЛ"),holdFor:0)}
        if verificationPath != nil {if CommandLine.arguments.contains("--verify-local") {verifyLocalState(state)} else {verifyState(state)};return}
        if state.ended && !state.ad && !endHandled {endHandled=true;if repeatMode==2 {engine.restart();endHandled=false} else {advance(1,automatic:true)}}
    }
    func format(_ value:Double)->String {guard value.isFinite,value>=0 else {return "--:--"};let n=Int(value);return String(format:"%02d:%02d",n/60,n%60)}
    func advance(_ direction:Int,automatic:Bool=false) {
        guard !queue.isEmpty else {return}
        var target=queueIndex+direction
        if target<0 {target=0}
        if target>=queue.count {if repeatMode==1 {target=0} else {transportIntent=automatic ? .stopped : .paused;view.updateTransport(transportIntent);engine.pause();if !automatic {status("КІНЕЦЬ ЧЕРГИ")};return}}
        queueIndex=target;play(queue[target])
    }
    func loadBrowse(_ id:String,title:String) {
        requestGeneration+=1;let generation=requestGeneration;requestTask?.cancel();status("ЗАВАНТАЖУЮ БІБЛІОТЕКУ…")
        requestTask=Task { @MainActor in
            do {let page=try await service.browse(id);guard !Task.isCancelled,generation==requestGeneration else {return};setPage(page,title:title,endpoint:"browse");status(page.items.isEmpty ? "ЦЕЙ РОЗДІЛ ПОРОЖНІЙ" : "ЗАВАНТАЖЕНО \(page.items.count) ЕЛЕМЕНТІВ")} catch {if !Task.isCancelled,generation==requestGeneration {status(error.localizedDescription)}}
        }
    }
    func act(_ action:String) {
        if installingSession && !["close","minimize"].contains(action) {status("ПІДКЛЮЧАЮ СЕСІЮ…");return}
        switch action {
        case "close":NSApp.terminate(nil)
        case "pin":windowGroup.setAlwaysOnTop(!windowGroup.alwaysOnTop)
        case "minimize":window.miniaturize(nil)
        case "toggleEQ":view.eqVisible.toggle();view.arrangeModules()
        case "togglePlaylist":view.playlistVisible.toggle();view.arrangeModules()
        case "toggleVideo":setVideoVisible(!videoVisible)
        case "volume":engine.volume(view.volume.value)
        case "seek":previousRewind=nil;if lastState?.hasSource != true {view.seek.value=0;status("СПОЧАТКУ ВІДКРИЙТЕ ТРЕК")} else if lastState?.ad != true {engine.seek(view.seek.value)}
        case "play":if current != nil {transportIntent = .playing;view.updateTransport(.loading);engine.resume()} else {activateSelection();if current==nil {status("ОБЕРІТЬ ТРЕК У СПИСКУ • ПОДВІЙНИЙ КЛІК")}}
        case "pause":if current != nil {transportIntent = .paused;view.updateTransport(.paused)};engine.pause()
        case "stop":if current != nil {transportIntent = .stopped;view.updateTransport(.stopped)};engine.stop()
        case "togglePlayback":act([TransportState.idle,.stopped,.failed].contains(view.transportState) ? "play" : transportIntent == .playing ? "pause" : "play")
        case "next":advance(1)
        case "previous":previousTrack()
        case "repeat":repeatMode=(repeatMode+1)%3;view.updateModes(shuffle:shuffleEnabled,repeatMode:repeatMode);refreshMediaCommands();status(["ПОВТОРЕННЯ ВИМКНЕНО","ПОВТОРЮВАТИ ЧЕРГУ","ПОВТОРЮВАТИ ОДИН ТРЕК"][repeatMode])
        case "shuffle":toggleShuffle()
        case "queue":requestGeneration+=1;requestTask?.cancel();setPage(MusicPage(items:queue,continuation:nil),title:"PLAYLIST EDITOR",endpoint:"browse")
        case "search":let query=view.query.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);guard !query.isEmpty else {window.makeFirstResponder(view.query);return};requestGeneration+=1;let generation=requestGeneration;requestTask?.cancel();status("ШУКАЮ…");requestTask=Task { @MainActor in do {let page=try await service.search(query);guard !Task.isCancelled,generation==requestGeneration else {return};setPage(page,title:"SEARCH RESULTS",endpoint:"search");status(page.items.isEmpty ? "НІЧОГО НЕ ЗНАЙДЕНО" : "\(page.items.count) РЕЗУЛЬТАТІВ • ПОДВІЙНИЙ КЛІК ДЛЯ ВІДТВОРЕННЯ")}catch {if !Task.isCancelled,generation==requestGeneration {status(error.localizedDescription)}}}
        case "more":guard let token=continuation else {status("БІЛЬШЕ ЕЛЕМЕНТІВ НЕМАЄ");return};requestGeneration+=1;let generation=requestGeneration,route=endpoint,title=view.sectionTitle;requestTask?.cancel();status("ЗАВАНТАЖУЮ ДАЛІ…");requestTask=Task { @MainActor in do {let page=try await service.more(token,endpoint:route);guard !Task.isCancelled,generation==requestGeneration else {return};setPage(page,title:title,endpoint:route,append:true);status("ЗАВАНТАЖЕНО \(items.count) ЕЛЕМЕНТІВ")}catch {if !Task.isCancelled,generation==requestGeneration {status(error.localizedDescription)}}}
        case "favorite":addCurrentFavorite()
        case "library":showLibraryMenu()
        case "openFiles":openLocalFiles()
        case "connect":showConnection()
        default:break
        }
    }
    @objc func openLocalFiles() {
        chooseLocalFiles(foldersOnly:false)
    }
    @discardableResult func importFiles(_ urls:[URL],autoplay:Bool=true)->Bool {
        guard !installingSession,window.attachedSheet==nil else {status("СПОЧАТКУ ЗАВЕРШІТЬ ВХІД");return false}
        if let skin=urls.first(where:{$0.pathExtension.lowercased()=="wsz"}) {loadSkin(skin);if urls.count==1 {return true}}
        requestGeneration+=1;let navigation=requestGeneration;requestTask?.cancel()
        let previous=importTask
        status("СКАНУЮ АУДІОФАЙЛИ Й ПАПКИ…")
        importTask=Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled,let self else {return}
            let result=await Task.detached(priority:.userInitiated) {LocalImporter.collect(urls)}.value
            guard !Task.isCancelled else {return}
            self.applyImport(result,autoplay:autoplay,navigation:navigation)
        }
        return true
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        let urls=filenames.map {URL(fileURLWithPath:$0)}
        if window==nil {pendingFileURLs+=urls;sender.reply(toOpenOrPrint:.success)} else {sender.reply(toOpenOrPrint:importFiles(urls) ? .success : .failure)}
    }
    func showLibraryMenu() {
        let menu=NSMenu()
        for (name,action) in [("Локальні файли",#selector(showLocalLibrary)),("Улюблені Retroamp",#selector(showFavorites)),("Додати папку…",#selector(openLocalFolder)),("Завантажити ще",#selector(loadMore))] {let item=NSMenuItem(title:name,action:action,keyEquivalent:"");item.target=self;menu.addItem(item)}
        menu.addItem(.separator())
        for (name,id) in [("Мої плейлисти","FEmusic_liked_playlists"),("Збережені пісні","FEmusic_liked_videos"),("Альбоми","FEmusic_liked_albums"),("Улюблені пісні","VLLM")] {
            let item=NSMenuItem(title:name,action:#selector(libraryChoice(_:)),keyEquivalent:"");item.target=self;item.representedObject=id;menu.addItem(item)
        }
        menu.addItem(.separator());let disconnect=NSMenuItem(title:"Відключити сесію",action:#selector(disconnectSession),keyEquivalent:"");disconnect.target=self;menu.addItem(disconnect);menu.popUp(positioning:nil,at:NSPoint(x:235,y:view.playlistView.bounds.height-42),in:view.playlistView)
    }
    @objc func libraryChoice(_ sender:NSMenuItem) {if credentials==nil {showConnection();return};if let id=sender.representedObject as? String {loadBrowse(id,title:sender.title)}}
    func showConnection() {
        guard connection==nil,!installingSession else {return}
        let sheet=ConnectionPanel();connection=sheet;authTask=nil
        sheet.cancelled={ [weak self] in self?.cancelConnection() }
        sheet.restored={ [weak self,weak sheet] in
            guard let self,let sheet,self.authTask==nil else {return}
            sheet.google.isEnabled=false;sheet.restore.isEnabled=false
            self.sessionGeneration+=1;let generation=self.sessionGeneration;self.startupTask?.cancel();self.favoriteTask?.cancel()
            self.authTask=Task { @MainActor [self] in
                do {
                    guard let saved=try KeychainSession.load(allowInteraction:true),saved.browserCookies != nil else {throw MusicError.message("Немає збереженої повної сесії. Натисніть «Увійти через Google».")}
                    guard !Task.isCancelled,generation==self.sessionGeneration else {return}
                    sheet.message.stringValue="Перевіряю збережену сесію YouTube Music…"
                    let page=try await self.service.authenticate(saved)
                    guard !Task.isCancelled,generation==self.sessionGeneration else {return}
                    self.installingSession=true;self.requestGeneration+=1;self.requestTask?.cancel()
                    // Validation succeeded. Close the cancellable panel before committing the session.
                    sheet.cancel.isEnabled=false
                    self.window.endSheet(sheet);sheet.orderOut(nil);self.connection=nil
                    guard await self.commitRestoredSession(generation:generation,serviceInstall:{await self.service.setSession(saved)},engineInstall:{await self.engine.installSession(saved,preserveLocal:true)}) else {return}
                    self.credentials=saved;self.installingSession=false;self.authTask=nil
                    if let active=self.current {if let id=active.videoID {self.engine.play(id)}} else if self.library.tracks.isEmpty {self.setPage(page,title:"MY PLAYLISTS",endpoint:"browse")}
                    self.status("ЗБЕРЕЖЕНИЙ ВХІД ВІДНОВЛЕНО • GOOGLE")
                } catch {
                    if !Task.isCancelled,generation==self.sessionGeneration {sheet.message.stringValue=error.localizedDescription;sheet.google.isEnabled=true;sheet.restore.isEnabled=true;self.authTask=nil;self.installingSession=false}
                }
            }
        }
        sheet.submitted={ [weak self,weak sheet] in
            guard let self,let sheet,self.authTask==nil else {return}
            sheet.google.isEnabled=false;sheet.restore.isEnabled=false
            sessionGeneration+=1;let generation=sessionGeneration;startupTask?.cancel();favoriteTask?.cancel()
            googleLogin.onStatus={ [weak sheet] message in sheet?.message.stringValue=message }
            self.authTask=Task { @MainActor [self] in
                do {
                    let (candidate,page)=try await self.googleLogin.signIn(service:self.service)
                    guard !Task.isCancelled,generation==self.sessionGeneration else {return}
                    try KeychainSession.save(candidate)
                    guard !Task.isCancelled,generation==self.sessionGeneration else {return}
                    self.googleLogin.cancel();self.credentials=candidate;self.installingSession=true;self.requestGeneration+=1;self.requestTask?.cancel()
                    self.window.endSheet(sheet);sheet.orderOut(nil);self.connection=nil
                    guard await self.commitRestoredSession(generation:generation,serviceInstall:{await self.service.setSession(candidate)},engineInstall:{await self.engine.installSession(candidate)}) else {return}
                    self.installingSession=false;self.authTask=nil;self.resetPlaybackDisplay();self.setPage(page,title:"MY PLAYLISTS",endpoint:"browse");self.status("GOOGLE ПІДКЛЮЧЕНО")
                } catch {
                    if !Task.isCancelled,generation==self.sessionGeneration {self.googleLogin.cancel();sheet.message.stringValue=error.localizedDescription;sheet.google.isEnabled=true;sheet.restore.isEnabled=true;self.authTask=nil;self.installingSession=false}
                }
            }
        }
        window.beginSheet(sheet)
    }
    func cancelConnection() {
        guard let sheet=connection else {return}
        if let task=authTask {sessionGeneration+=1;task.cancel();authTask=nil;installingSession=false;googleLogin.cancel()}
        window.endSheet(sheet);sheet.orderOut(nil);connection=nil
    }
    func resetPlaybackDisplay() {
        view.resetMarquees()
        current=nil;lastState=nil;queue=[];queueIndex = -1;endHandled=false
        updateVideoTrack()
        previousRewind=nil;orderedQueue=[];transportIntent = .idle;view.updateTransport(.idle)
        mediaControls.clear();view.spectrumDynamics.reset();view.spectrumInput=Array(repeating:0,count:37);updateFavoriteButton()
        view.spectrum=Array(repeating:0,count:37);view.peaks=Array(repeating:0,count:37);view.updateClock(time:0,duration:0);view.durationLine="";view.isPlaying=false;view.hasSource=false;view.seek.value=0
        view.titleLine="YOUTUBE MUSIC";view.artistLine="Оберіть трек у списку.";view.needsDisplay=true
    }
    func handlesTransportKey(_ event:NSEvent)->Bool {
        transportKeyAction(event) != nil
    }
    @objc func disconnectSession() {
        cancelConnection();sessionGeneration+=1;authTask?.cancel();startupTask?.cancel();favoriteTask?.cancel();installingSession=false;requestGeneration+=1;requestTask?.cancel()
        do {try KeychainSession.delete();credentials=nil;resetPlaybackDisplay();engine.pause();Task { @MainActor in await service.setSession(nil);await engine.installSession(nil)};setPage(MusicPage(items:[],continuation:nil),title:"PLAYLIST EDITOR",endpoint:"search");view.titleLine="YOUTUBE MUSIC";view.artistLine="Сесію відключено.";view.updateClock(time:0,duration:0);status("СЕСІЮ ВИДАЛЕНО З KEYCHAIN")} catch {status(error.localizedDescription)}
    }
    func checkUI(_ path:String) {
        let track=MusicItem(id:"4D7u5KF7SP8",title:"Fixture",subtitle:"",videoID:"4D7u5KF7SP8",browseID:nil,duration:"6:10")
        items=[track];view.rows=[track.title];view.table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        installingSession=true;activateSelection()
        var result:[String:Bool]=["doubleClickBlockedDuringSessionInstall":current==nil]
        installingSession=false;current=track;queue=[track];queueIndex=0;view.clock="01:00";view.isPlaying=true;view.hasSource=true
        resetPlaybackDisplay()
        result["sessionResetClearsPlayerState"]=current==nil && lastState==nil && queue.isEmpty && view.clock==(view.remainingTime ? "−00:00" : "00:00") && !view.isPlaying && !view.hasSource
        let generation=sessionGeneration
        startupTask=Task {try? await Task.sleep(nanoseconds:2_000_000_000)}
        showConnection()
        guard let panel=connection else {NSApp.terminate(nil);return}
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:panel.windowNumber,context:nil,characters:" ",charactersIgnoringModifiers:" ",isARepeat:false,keyCode:49)!
        result["spaceNotCapturedFromConnectionPanel"] = !handlesTransportKey(event)
        result["googleButtonPresent"]=panel.google.title=="Увійти через Google"
        cancelConnection()
        result["cancelPanelPreservesStartupRestore"]=startupTask?.isCancelled==false && generation==sessionGeneration
        let data=try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        try! data.write(to:URL(fileURLWithPath:path));NSApp.terminate(nil)
    }
    func saveRender(_ path:String) {view.displayIfNeeded();if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {view.cacheDisplay(in:view.bounds,to:bitmap);try? bitmap.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:path))}}
    func verifyState(_ state:PlaybackState) {
        guard !engine.isLocal else {return}
        if state.ad {
            verification["adObserved"]=true
            if adTestStage==0,state.hasSource,state.duration>=10,state.time<3 {
                adTestStage=1;act("pause")
            } else if adTestStage==1,state.paused {
                adTestTime=state.time;adTestDuration=state.duration;adTestStage=2;engine.seek(0.9)
            } else if adTestStage==2,state.paused {
                verification["adSeekBlocked"]=abs(state.time-adTestTime)<0.5 && abs(state.duration-adTestDuration)<0.5
                verification["adSeekBefore"]=adTestTime;verification["adSeekAfter"]=state.time
                adTestStage=3;act("play")
            }
            return
        }
        guard state.hasSource,state.duration>60 else {return}
        verification["duration"]=state.duration
        if verificationStage<5,let seconds=engine.lastStartupSeconds {verification["firstMusicSignalSeconds"]=seconds}
        verification["mutedVerification"]=state.muted
        if let seconds=engine.lastMediaSignalSeconds {verification[verificationStage<5 ? "firstAudioSignalSeconds" : verificationStage==9 ? "recoveredAudioSignalSeconds" : "warmAudioSignalSeconds"]=seconds}
        if verificationStage==0,state.time>3,!state.paused {verification["streamPlaying"]=true;verification["stopDuringLoadThenPlay"]=true;verification["beforePauseTime"]=state.time;if CommandLine.arguments.contains("--verify-race") {verification["rapidSelectionVerified"]=current?.videoID=="4D7u5KF7SP8" && abs(state.duration-370)<2};saveRender(URL(fileURLWithPath:verificationPath!).deletingLastPathComponent().appendingPathComponent("equalizer-live-preview.png").path);verificationStage=1;act("pause")}
        else if verificationStage==1,state.paused {verification["pause"]=abs(state.time-(verification["beforePauseTime"] as? Double ?? -100))<0.25;verificationStage=2;view.seek.value=0.5;act("seek")}
        else if verificationStage==2,abs(state.time-state.duration/2)<2 {verification["seek"]=true;verificationStage=3;view.volume.value=0.17;act("volume");act("play")}
        else if verificationStage==3,!state.paused,state.time>state.duration/2+1 {verification["resume"]=true;verification["volume"]=abs(state.volume-0.17)<0.001;verificationStage=4;act("stop")}
        else if verificationStage==4,state.paused,state.time<1 {
            verification["stop"]=true
            if CommandLine.arguments.contains("--verify-warm") {verificationStage=5;let next=MusicItem(id:"4D7u5KF7SP8",title:"Get Lucky",subtitle:"Daft Punk",videoID:"4D7u5KF7SP8",browseID:nil,duration:"");play(next)} else {finishVerification()}
        } else if verificationStage==5,!state.paused,state.time>1,let seconds=engine.lastStartupSeconds {
            verification["warmTrackSignalSeconds"]=seconds;verification["warmTrackPlaying"]=true
            if CommandLine.arguments.contains("--verify-lifecycle") {verificationStage=6;engine.checkEndTrack()} else {verificationStage=10;finishVerification()}
        }
        else if verificationStage==6,state.ended {verification["naturalTrackEnd"]=true;verificationStage=7;engine.resume()}
        else if verificationStage==7,!state.paused,state.time>1,state.time<6 {verification["playAfterEnd"]=true;verificationStage=8;engine.checkDisconnect()}
        else if verificationStage==9,!state.paused,state.time>1 {verification["browserRecovery"]=true;verificationStage=10;finishVerification()}
    }
    func verifyLocalState(_ state:PlaybackState) {
        guard state.hasSource,state.duration>2 else {return}
        verification["mutedVerification"]=state.muted
        if verificationStage==0,state.time>0.3,!state.paused {verification["localPlaying"]=true;verification["startupSeconds"]=Date().timeIntervalSince(requestedPlaybackAt);verificationStage=1;engine.pause()}
        else if verificationStage==1,state.paused {verification["pause"]=true;verificationStage=2;engine.seek(0.5)}
        else if verificationStage==2,state.paused,abs(state.time-state.duration/2)<0.2 {verification["seek"]=true;verificationStage=3;engine.resume()}
        else if verificationStage==3,!state.paused,state.time>state.duration/2+0.2 {verification["resume"]=true;verificationStage=4;engine.stop()}
        else if verificationStage==4,state.paused,state.time<0.1 {verification["stop"]=true;verificationStage=5;engine.restart();engine.seek(0.96)}
        else if verificationStage==5,state.ended {verification["naturalEnd"]=true;verificationStage=6;engine.resume()}
        else if verificationStage==6,!state.paused,state.time>0.1,state.time<1 {verification["playAfterEnd"]=true;verificationStage=7;act("next")}
        else if verificationStage==7,current?.id==queue.dropFirst().first?.id,!state.paused,state.time>0.1 {verification["nextTrack"]=true;verificationStage=8;finishLocalVerification()}
    }
    func finishLocalVerification() {
        guard let path=verificationPath,!finishingVerification else {return}
        finishingVerification=true;engine.onState=nil;engine.onSpectrum=nil;engine.pause();view.spectrumTimer?.invalidate();verificationPath=nil
        verification["completed"]=verificationStage==8 && ["localPlaying","pause","seek","resume","stop","naturalEnd","playAfterEnd","nextTrack","localAllPlayable"].allSatisfy {verification[$0] as? Bool==true}
        verification["realSpectrumVerified"]=(verification["spectrumNonzeroFrames"] as? Int ?? 0)>3
        verification["finalVerificationStage"]=verificationStage
        if let data=try? JSONSerialization.data(withJSONObject:verification,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path))}
        saveRender(URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("local-playback.png").path);NSApp.terminate(nil)
    }
    func finishVerification() {
        guard let path=verificationPath,!finishingVerification else {return}
        finishingVerification=true;engine.onState=nil;engine.onSpectrum=nil;engine.pause();view.spectrumTimer?.invalidate();verificationPath=nil
        let basePassed=(verificationStage==4 || verificationStage==10) && ["streamPlaying","pause","seek","resume","stop","volume","searchContainsGetLucky"].allSatisfy {verification[$0] as? Bool == true}
        let racePassed = !CommandLine.arguments.contains("--verify-race") || verification["rapidSelectionVerified"] as? Bool==true
        let lifecyclePassed = !CommandLine.arguments.contains("--verify-lifecycle") || ["naturalTrackEnd","playAfterEnd","browserRecovery"].allSatisfy {verification[$0] as? Bool==true}
        let warmPassed = !CommandLine.arguments.contains("--verify-warm") || verification["warmTrackPlaying"] as? Bool==true
        verification["completed"]=basePassed && racePassed && lifecyclePassed && warmPassed;verification["finalVerificationStage"]=verificationStage;verification["uiIsNative"]=true;verification["realSpectrumVerified"]=(verification["spectrumNonzeroFrames"] as? Int ?? 0)>10;verification["authenticatedLibraryVerified"]=false
        if let data=try? JSONSerialization.data(withJSONObject:verification,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:URL(fileURLWithPath:path))}
        saveRender(URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("native-runtime.png").path)
        NSApp.terminate(nil)
    }
    func cancelWorkForTermination(){
        sessionGeneration+=1;requestGeneration+=1
        startupTask?.cancel();authTask?.cancel();requestTask?.cancel();favoriteTask?.cancel();importTask?.cancel();skinTask?.cancel();googleLogin.cancel()
    }
    private var streamTerminating=false,streamCanExit=false
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if streamCanExit{return .terminateNow}
        if !streamTerminating {
            streamTerminating=true;cancelWorkForTermination();engine.beginShutdown()
            Task{@MainActor in if await engine.shutdownStreaming(){streamCanExit=true;NSApp.terminate(nil)}else{streamTerminating=false;status("Джерело ще завершується. Повторіть закриття.")}}
        }
        // Returning first lets the MainActor drain even when quit originated in a Swift task.
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification:Notification) {importTask?.cancel();favoriteTask?.cancel();mediaControls.shutdown();requestTask?.cancel();authTask?.cancel();startupTask?.cancel();skinTask?.cancel();googleLogin.cancel();view.spectrumTimer?.invalidate();engine.shutdown();if let eventMonitor {NSEvent.removeMonitor(eventMonitor)}}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {window.deminiaturize(nil);showModules();window.makeKeyAndOrderFront(nil);return true}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {true}
}
let app=NSApplication.shared
app.setActivationPolicy(.regular)
let delegate=MainActor.assumeIsolated {AppDelegate()};app.delegate=delegate
app.run()
