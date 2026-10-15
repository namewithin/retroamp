import AppKit

struct EqualizerSettings: Codable {
    static let frequencies: [Float] = [31,63,125,250,500,1000,2000,4000,8000,16000]
    static let labels = ["31","63","125","250","500","1K","2K","4K","8K","16K"]
    var enabled = true
    var preamp: Float = 0
    var gains = [Float](repeating:0,count:10)
    static func load() -> Self {
        guard let data=UserDefaults.standard.data(forKey:"equalizer.v1"),let value=try? JSONDecoder().decode(Self.self,from:data),value.gains.count==10,value.gains.allSatisfy({$0.isFinite && abs($0)<=12}),value.preamp.isFinite,abs(value.preamp)<=12 else {return Self()}
        return value
    }
    func save() {if let data=try? JSONEncoder().encode(self) {UserDefaults.standard.set(data,forKey:"equalizer.v1")}}

}

final class BandSlider: NSControl {
    var gain: Float = 0 {didSet {needsDisplay=true;setAccessibilityValue(String(format:"%+.1f dB",gain))}}
    override var acceptsFirstResponder: Bool {true}
    override var isFlipped: Bool {true}
    override init(frame:NSRect) {super.init(frame:frame);setAccessibilityElement(true);setAccessibilityRole(.slider)}
    required init?(coder:NSCoder) {fatalError()}
    override func draw(_ dirtyRect:NSRect) {
        if let skin=activeSkin {
            let frame=min(27,max(0,Int((12-gain)/24*27)))
            let background=NSRect(x:13+CGFloat(frame%15)*14,y:164+CGFloat(frame/15)*65,width:14,height:63)
            if skin.draw("eqmain",background,bounds) {skin.draw("eqmain",NSRect(x:0,y:164,width:11,height:11),NSRect(x:bounds.width*1.5/14,y:CGFloat((12-gain)/24)*(bounds.height-bounds.height*11/63),width:bounds.width*11/14,height:bounds.height*11/63));return}
        }
        let track=NSRect(x:bounds.midX-2,y:5,width:4,height:bounds.height-10)
        fill(track,tag%3==0 ? .systemYellow : tag%3==1 ? green : .systemOrange)
        fill(NSRect(x:3,y:bounds.midY,width:bounds.width-6,height:1),dimGreen)
        let y=5+CGFloat((12-gain)/24)*(bounds.height-10)
        let knob=NSRect(x:bounds.midX-7,y:y-4,width:14,height:8)
        fill(knob,NSColor(calibratedRed:0.62,green:0.67,blue:0.72,alpha:1));bevel(knob)
        fill(NSRect(x:knob.minX+4,y:knob.midY,width:12,height:1),.black)
    }
    override func mouseDown(with event:NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount==2 {gain=0;_ = sendAction(action,to:target);return}
        var current:NSEvent?=event
        while let e=current {
            let y=convert(e.locationInWindow,from:nil).y
            gain=min(12,max(-12,Float(12-24*(y-5)/max(1,bounds.height-10))))
            _ = sendAction(action,to:target)
            if e.type == .leftMouseUp {break}
            current=window?.nextEvent(matching:[.leftMouseDragged,.leftMouseUp])
        }
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode==126 {gain=min(12,gain+1)} else if event.keyCode==125 {gain=max(-12,gain-1)} else {super.keyDown(with:event);return}
        _ = sendAction(action,to:target)
    }
}

final class EqualizerView:NSView {
    override var isFlipped:Bool {true}
    var settings=EqualizerSettings.load()
    var onChange:((EqualizerSettings)->Void)?
    let toggle=MetalButton(frame:NSRect(x:12,y:24,width:37,height:17))
    let closeButton=MetalButton(frame:NSRect(x:338,y:4,width:13,height:11))
    var onClose:(()->Void)?
    let reset=MetalButton(frame:NSRect(x:53,y:24,width:44,height:17))
    let preset=MetalButton(frame:NSRect(x:292,y:24,width:56,height:17))
    var sliders:[BandSlider]=[]
    private let presets:[String]=["Flat","Rock","Bass","Vocal","Electronic"]
    override init(frame:NSRect) {
        super.init(frame:frame)
        toggle.target=self;toggle.action=#selector(toggleEQ);toggle.isBordered=false;toggle.setAccessibilityLabel("Увімкнути еквалайзер");addSubview(toggle)
        reset.title="RESET";reset.target=self;reset.action=#selector(resetEQ);reset.isBordered=false;addSubview(reset)
        preset.title="PRESETS";preset.target=self;preset.action=#selector(showPresets);preset.isBordered=false;preset.setAccessibilityLabel("Пресети еквалайзера");addSubview(preset)
        for i in 0..<11 {
            let slider=BandSlider(frame:NSRect(x:i==0 ? 21 : 74+CGFloat(i-1)*27,y:53,width:18,height:64))
            slider.tag=i;slider.setAccessibilityLabel(i==0 ? "Preamp" : "\(EqualizerSettings.labels[i-1]) Hz");slider.target=self;slider.action=#selector(sliderChanged(_:));addSubview(slider);sliders.append(slider)
        }
        closeButton.title="×";closeButton.skinRole="eqClose";closeButton.isBordered=false;closeButton.target=self;closeButton.action=#selector(closePanel);closeButton.setAccessibilityLabel("Приховати еквалайзер");addSubview(closeButton)
        toggle.skinRole="eqOn";preset.skinRole="eqPreset"
        syncControls()
    }
    required init?(coder:NSCoder) {fatalError()}
    func syncControls() {
        toggle.title=settings.enabled ? "ON" : "OFF";toggle.skinSelected=settings.enabled;toggle.toolTip=settings.enabled ? "Еквалайзер увімкнено" : "Еквалайзер вимкнено";toggle.needsDisplay=true
        for (i,slider) in sliders.enumerated() {slider.gain=i==0 ? settings.preamp : settings.gains[i-1]}
        needsDisplay=true
    }
    func changed() {syncControls();settings.save();onChange?(settings)}
    @objc func toggleEQ() {settings.enabled.toggle();changed()}
    @objc func resetEQ() {settings.preamp=0;settings.gains=Array(repeating:0,count:10);changed()}
    @objc func sliderChanged(_ sender:BandSlider) {if sender.tag==0 {settings.preamp=sender.gain} else {settings.gains[sender.tag-1]=sender.gain};changed()}
    @objc func showPresets() {
        let menu=NSMenu()
        for (index,name) in presets.enumerated() {let item=NSMenuItem(title:name,action:#selector(choosePreset(_:)),keyEquivalent:"");item.tag=index;item.target=self;menu.addItem(item)}
        menu.popUp(positioning:nil,at:NSPoint(x:292,y:43),in:self)
    }
    @objc func choosePreset(_ sender:NSMenuItem) {
        let values:[[Float]]=[Array(repeating:0,count:10),[4,3,2,0,-2,-1,2,4,4,3],[6,5,4,2,0,-1,-1,0,0,0],[-3,-2,-1,1,3,4,3,1,-1,-2],[4,3,0,-2,-2,0,2,3,4,4]]
        guard values.indices.contains(sender.tag) else {return}
        settings.gains=values[sender.tag];settings.preamp=sender.tag==0 ? 0 : -4;changed()
    }
    @objc func closePanel() {onClose?()}
    override func mouseDown(with event:NSEvent) {if convert(event.locationInWindow,from:nil).y<20 {if let w=window as? RetroWindow,let group=w.group {group.dragWindow(w,with:event)} else {window?.performDrag(with:event)}}}
    func scaled(_ r:NSRect)->NSRect {NSRect(x:r.minX*360/275,y:r.minY*140/116,width:r.width*360/275,height:r.height*140/116)}
    func applySkinLayout() {
        let skinned=activeSkin != nil
        toggle.frame=skinned ? scaled(NSRect(x:14,y:18,width:26,height:12)) : NSRect(x:12,y:24,width:37,height:17)
        preset.frame=skinned ? scaled(NSRect(x:217,y:18,width:44,height:12)) : NSRect(x:292,y:24,width:56,height:17)
        reset.frame=skinned ? scaled(NSRect(x:42,y:18,width:32,height:12)) : NSRect(x:53,y:24,width:44,height:17)
        closeButton.frame=skinned ? scaled(NSRect(x:264,y:3,width:9,height:9)) : NSRect(x:338,y:4,width:13,height:11)
        for (i,slider) in sliders.enumerated() {slider.frame=skinned ? scaled(NSRect(x:i==0 ? 21 : 78+CGFloat(i-1)*18,y:38,width:14,height:63)) : NSRect(x:i==0 ? 21 : 74+CGFloat(i-1)*27,y:53,width:18,height:64);slider.needsDisplay=true}
        needsDisplay=true
    }
    override func draw(_ dirtyRect:NSRect) {
        if let skin=activeSkin,skin.drawEqualizer(in:bounds,selected:window?.isKeyWindow==true) {
            let chart=scaled(NSRect(x:86,y:17,width:113,height:19))
            skin.draw("eqmain",NSRect(x:0,y:294,width:113,height:19),chart)
            let p=NSBezierPath();p.lineWidth=1;for i in 0..<10 {let gain=settings.enabled ? settings.gains[i]+settings.preamp : 0,point=NSPoint(x:chart.minX+CGFloat(i)*chart.width/9,y:chart.midY-CGFloat(min(12,max(-12,gain)))*chart.height/24);if i==0 {p.move(to:point)} else {p.line(to:point)}};skin.textColor.setStroke();p.stroke()
            fill(scaled(NSRect(x:74,y:103,width:190,height:11)),skin.pixelColor("eqmain",x:75,y:103) ?? graphite)
            for i in 0..<10 {text(EqualizerSettings.labels[i],scaled(NSRect(x:76+CGFloat(i)*18,y:105,width:18,height:10)),size:8,color:skin.textColor)}
            return
        }
        fill(bounds,graphite);bevel(bounds)
        let gold=NSColor(calibratedRed:0.80,green:0.75,blue:0.51,alpha:1)
        for y in [7.0,10.0] {fill(NSRect(x:10,y:y,width:112,height:1),gold);fill(NSRect(x:239,y:y,width:110,height:1),gold)}
        text("EQUALIZER",NSRect(x:133,y:3,width:100,height:14),size:9,color:.lightGray,bold:true)
        let chart=NSRect(x:106,y:24,width:174,height:20);fill(chart,NSColor(calibratedWhite:0.09,alpha:1))
        for i in 0..<10 {fill(NSRect(x:chart.minX+CGFloat(i)*chart.width/9,y:chart.minY,width:1,height:chart.height),NSColor(calibratedWhite:0.20,alpha:1))}
        fill(NSRect(x:chart.minX,y:chart.midY,width:chart.width,height:1),NSColor(calibratedWhite:0.22,alpha:1))
        let curve=NSBezierPath();curve.lineWidth=1
        for i in 0..<10 {let gain=settings.enabled ? settings.gains[i]+settings.preamp : 0;let point=NSPoint(x:chart.minX+CGFloat(i)*chart.width/9,y:chart.midY-CGFloat(min(12,max(-12,gain)))*chart.height/24);if i==0 {curve.move(to:point)} else {curve.line(to:point)}}
        gold.setStroke();curve.stroke()
        text("+12",NSRect(x:45,y:51,width:28,height:11),size:7,color:gold);text("0",NSRect(x:49,y:82,width:14,height:11),size:7,color:gold);text("−12",NSRect(x:45,y:108,width:28,height:11),size:7,color:gold)
        text("PRE",NSRect(x:18,y:122,width:29,height:11),size:7,color:.lightGray)
        for i in 0..<10 {text(EqualizerSettings.labels[i],NSRect(x:73+CGFloat(i)*27,y:122,width:27,height:11),size:7,color:.lightGray)}
    }
}
