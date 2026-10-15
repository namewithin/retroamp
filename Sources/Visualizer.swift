import AppKit

struct VisualizerSettings:Codable,Equatable {
    var sensitivity:Float = -4
    var range:Float = 50
    var release:Double = 0.14
    var fps:Double = 24
    static func load()->Self {
        guard let data=UserDefaults.standard.data(forKey:"visualizer.v1"),let s=try? JSONDecoder().decode(Self.self,from:data),
              s.sensitivity.isFinite,(-12...12).contains(s.sensitivity),s.range.isFinite,(35...70).contains(s.range),
              s.release.isFinite,(0.06...0.5).contains(s.release),[15.0,24.0,30.0].contains(s.fps) else {return Self()}
        return s
    }
    func save() {if let data=try? JSONEncoder().encode(self) {UserDefaults.standard.set(data,forKey:"visualizer.v1")}}
    func level(_ input:Float)->Float {
        guard input.isFinite,input>0 else {return 0}
        let db=input*90-90+sensitivity
        return min(1,max(0,(db+5+range)/range))
    }
}

final class SpectrumDynamics {
    private(set) var levels=[Float](repeating:0,count:37),peaks=[Float](repeating:0,count:37)
    private var hold=[Double](repeating:0,count:37)
    var hasActivity:Bool {levels.contains {$0>0} || peaks.contains {$0>0}}
    func reset() {levels=Array(repeating:0,count:37);peaks=levels;hold=Array(repeating:0,count:37)}
    func step(input:[Float],playing:Bool,delta:Double,settings:VisualizerSettings) {
        guard input.count==37 else {return}
        let dt=min(0.2,max(0,delta))
        for i in 0..<37 {
            let target=playing ? settings.level(input[i]) : 0
            let seconds=target>levels[i] ? 0.035 : settings.release
            levels[i]+=(target-levels[i])*Float(1-exp(-dt/seconds))
            if levels[i]<0.001 {levels[i]=0}
            if levels[i]>=peaks[i] {peaks[i]=levels[i];hold[i]=0.18}
            else {hold[i]=max(0,hold[i]-dt);if hold[i]==0 {peaks[i]=max(levels[i],peaks[i]-Float(dt)*0.8)}}
        }
    }
}

@MainActor final class SettingsWindow:NSWindowController {
    var onChange:((VisualizerSettings)->Void)?
    private(set) var settings:VisualizerSettings
    private var sliders:[NSSlider]=[],values:[NSTextField]=[]
    private let rate=NSPopUpButton()
    init(settings:VisualizerSettings) {
        self.settings=settings
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:430,height:310),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Налаштування Retroamp";window.isReleasedWhenClosed=false
        super.init(window:window)
        guard let content=window.contentView else {return}
        func label(_ title:String,_ frame:NSRect,size:CGFloat=11)->NSTextField {
            let l=NSTextField(labelWithString:title);l.font=drawingFont(size:size,bold:false);l.frame=frame;content.addSubview(l);return l
        }
        _=label("ВІЗУАЛАЙЗЕР",NSRect(x:22,y:268,width:380,height:20),size:12)
        for (i,name) in ["Чутливість","Діапазон","Плавність спаду"].enumerated() {
            let y=CGFloat(228-i*45)
            _=label(name,NSRect(x:22,y:y,width:142,height:20))
            let slider=NSSlider(value:0,minValue:[-12,35,0.06][i],maxValue:[12,70,0.5][i],target:self,action:#selector(changed(_:)))
            slider.tag=i;slider.isContinuous=true;slider.frame=NSRect(x:164,y:y,width:174,height:20);slider.setAccessibilityLabel(name);content.addSubview(slider);sliders.append(slider)
            values.append(label("",NSRect(x:346,y:y,width:75,height:20),size:10))
        }
        _=label("Частота кадрів",NSRect(x:22,y:93,width:142,height:22))
        rate.frame=NSRect(x:164,y:91,width:120,height:26);rate.addItems(withTitles:["15 кадрів/с","24 кадри/с","30 кадрів/с"]);rate.font=drawingFont(size:11,bold:false);rate.target=self;rate.action=#selector(rateChanged);content.addSubview(rate)
        _=label("Налаштування змінюють лише спектр, не звук.",NSRect(x:22,y:55,width:392,height:20),size:9)
        let reset=NSButton(title:"Відновити стандартні",target:self,action:#selector(reset));reset.font=drawingFont(size:10,bold:false);reset.bezelStyle = .rounded;reset.frame=NSRect(x:22,y:17,width:210,height:30);content.addSubview(reset)
        sync();window.center()
    }
    required init?(coder:NSCoder) {fatalError()}
    private func sync() {
        sliders[0].doubleValue=Double(settings.sensitivity);sliders[1].doubleValue=Double(settings.range);sliders[2].doubleValue=settings.release
        values[0].stringValue=String(format:"%+.0f dB",settings.sensitivity);values[1].stringValue=String(format:"%.0f dB",settings.range);values[2].stringValue=String(format:"%.0f мс",settings.release*1000)
        rate.selectItem(at:[15.0,24.0,30.0].firstIndex(of:settings.fps) ?? 1)
    }
    private func emit() {sync();settings.save();onChange?(settings)}
    @objc private func changed(_ sender:NSSlider) {
        switch sender.tag {case 0:settings.sensitivity=Float(sender.doubleValue);case 1:settings.range=Float(sender.doubleValue);default:settings.release=sender.doubleValue};emit()
    }
    @objc private func rateChanged() {settings.fps=[15.0,24.0,30.0][rate.indexOfSelectedItem];emit()}
    @objc private func reset() {settings=VisualizerSettings();emit()}
}
