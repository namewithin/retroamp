import AVFoundation
import Accelerate

extension EqualizerSettings {
    func apply(to unit:AVAudioUnitEQ,sampleRate:Double=48000) {
        unit.globalGain=enabled ? preamp : 0
        for (i,band) in unit.bands.enumerated() {
            band.filterType = .parametric;band.frequency=min(Self.frequencies[i],Float(sampleRate*0.475));band.bandwidth=1
            band.gain=enabled ? gains[i] : 0;band.bypass = !enabled
        }
    }
}

@MainActor final class LocalAudioEngine {
    var onState:((PlaybackState)->Void)?
    var onSpectrum:(([Float])->Void)?
    var onError:((String)->Void)?
    private let audio=AVAudioEngine(),player=AVAudioPlayerNode(),eq=AVAudioUnitEQ(numberOfBands:10)
    private let analyser=SpectrumAnalyser()
    private var file:AVAudioFile?
    private var requestedURL:URL?
    private var scopedURL:URL?
    private var hasScope=false
    private var settings=EqualizerSettings.load()
    private var timer:Timer?
    private var generation=0
    private var tapInstalled=false
    private var baseFrame:AVAudioFramePosition=0
    private var pausedTime=0.0
    private var ended=false
    private var level=0.15
    private var muted=false
    init() {
        audio.attach(player);audio.attach(eq)
        timer=Timer.scheduledTimer(withTimeInterval:0.08,repeats:true) {[weak self] _ in MainActor.assumeIsolated {self?.emit()}}
    }
    func open(_ url:URL) {
        requestedURL=url
        stopGraph();releaseScope();file=nil;pausedTime=0;baseFrame=0;ended=false
        scopedURL=url;hasScope=url.startAccessingSecurityScopedResource()
        do {
            let f=try AVAudioFile(forReading:url)
            guard f.length>0,Double(f.length)<Double(UInt32.max) else {throw MusicError.message("Файл порожній або задовгий.")}
            audio.connect(player,to:eq,format:f.processingFormat);audio.connect(eq,to:audio.mainMixerNode,format:f.processingFormat)
            file=f;settings.apply(to:eq,sampleRate:f.processingFormat.sampleRate)
            audio.mainMixerNode.outputVolume=muted ? 0 : Float(level)
            let token=generation
            eq.installTap(onBus:0,bufferSize:2048,format:f.processingFormat) {[weak self,analyser] buffer,_ in
                if let levels=analyser.analyse(buffer) {Task { @MainActor [weak self] in guard let self,self.generation==token else {return};self.onSpectrum?(levels)}}
            };tapInstalled=true
            audio.prepare();try audio.start();schedule(0);player.play();emit()
        } catch {stopGraph();file=nil;releaseScope();onSpectrum?(Array(repeating:0,count:37));onError?("Не вдалося відкрити \(url.lastPathComponent): \(error.localizedDescription)");emit()}
    }
    private var duration:Double {file.map {Double($0.length)/$0.processingFormat.sampleRate} ?? 0}
    private var time:Double {
        guard let file else {return 0};if ended {return duration};if !player.isPlaying {return pausedTime}
        let frames=player.lastRenderTime.flatMap {player.playerTime(forNodeTime:$0)}?.sampleTime ?? 0
        return min(duration,Double(baseFrame+max(0,frames))/file.processingFormat.sampleRate)
    }
    private var segment=0
    private func schedule(_ seconds:Double) {
        guard let file else {return};segment+=1;let token=segment
        player.stop();ended=false;pausedTime=min(duration,max(0,seconds))
        baseFrame=min(file.length-1,max(0,AVAudioFramePosition(pausedTime*file.processingFormat.sampleRate)))
        player.scheduleSegment(file,startingFrame:baseFrame,frameCount:AVAudioFrameCount(file.length-baseFrame),at:nil,completionCallbackType:.dataPlayedBack) {[weak self] _ in
            Task { @MainActor [weak self] in guard let self,self.segment==token else {return};self.ended=true;self.emit()}
        }
    }
    func resume() {if file==nil,let requestedURL {open(requestedURL);return};if ended {schedule(0)};if file != nil {player.play()};emit()}
    func restart() {if file==nil,let requestedURL {open(requestedURL);return};schedule(0);if file != nil {player.play()};emit()}
    func pause() {pausedTime=time;player.pause();onSpectrum?(Array(repeating:0,count:37));emit()}
    func stop() {schedule(0);onSpectrum?(Array(repeating:0,count:37));emit()}
    func seek(_ fraction:Double) {let playing=player.isPlaying;schedule(min(1,max(0,fraction))*duration);if playing {player.play()};emit()}
    func volume(_ value:Double) {level=value;audio.mainMixerNode.outputVolume=muted ? 0 : Float(level)}
    func mute(_ value:Bool) {muted=value;audio.mainMixerNode.outputVolume=muted ? 0 : Float(level)}
    func equalizerSettings(_ value:EqualizerSettings) {settings=value;value.apply(to:eq,sampleRate:file?.processingFormat.sampleRate ?? 48000)}
    private func emit() {onState?(PlaybackState(time:time,duration:duration,paused:!player.isPlaying,ended:ended,hasSource:file != nil,ad:false,title:"",artist:"",error:"",volume:level,muted:muted))}
    private func stopGraph() {generation+=1;segment+=1;player.stop();audio.stop();if tapInstalled {eq.removeTap(onBus:0);tapInstalled=false}}
    private func releaseScope() {if hasScope {scopedURL?.stopAccessingSecurityScopedResource()};hasScope=false;scopedURL=nil}
    func shutdown() {timer?.invalidate();timer=nil;stopGraph();file=nil;requestedURL=nil;releaseScope()}
}

final class SpectrumAnalyser {
    private let size=2048
    private let setup=vDSP_create_fftsetup(11,FFTRadix(kFFTRadix2))!
    private var lastFrameTime:Double=0
    deinit {vDSP_destroy_fftsetup(setup)}
    func analyse(_ buffer:AVAudioPCMBuffer) -> [Float]? {
        let now=CFAbsoluteTimeGetCurrent();guard now-lastFrameTime>=1.0/24,buffer.frameLength>=2048,let channels=buffer.floatChannelData else {return nil};lastFrameTime=now
        var window=[Float](repeating:0,count:size),power=[Float](repeating:0,count:size/2)
        vDSP_hann_window(&window,vDSP_Length(size),Int32(vDSP_HANN_NORM))
        let count=Int(buffer.format.channelCount)
        for channel in 0..<count {
            var samples=Array(UnsafeBufferPointer(start:channels[channel],count:size))
            vDSP_vmul(samples,1,window,1,&samples,1,vDSP_Length(size))
            var real=[Float](repeating:0,count:size/2),imag=[Float](repeating:0,count:size/2),channelPower=[Float](repeating:0,count:size/2)
            real.withUnsafeMutableBufferPointer {r in imag.withUnsafeMutableBufferPointer {im in
                var split=DSPSplitComplex(realp:r.baseAddress!,imagp:im.baseAddress!)
                samples.withUnsafeBufferPointer {s in s.baseAddress!.withMemoryRebound(to:DSPComplex.self,capacity:size/2) {vDSP_ctoz($0,2,&split,1,vDSP_Length(size/2))}}
                vDSP_fft_zrip(setup,&split,1,11,FFTDirection(FFT_FORWARD));vDSP_zvmags(&split,1,&channelPower,1,vDSP_Length(size/2))
            }}
            for i in 0..<size/2 {power[i]+=channelPower[i]/Float(count)}
        }
        let bin=Float(buffer.format.sampleRate)/Float(size)
        return (0..<37).map {band in
            let low=Float(30*pow(600,Double(band)/37)),high=Float(30*pow(600,Double(band+1)/37))
            let start=min(size/2-1,max(1,Int(low/bin))),end=min(size/2-1,max(start,Int(high/bin)))
            let amplitude=sqrt(power[start...end].max() ?? 0)/Float(size)
            let db=20*log10(max(0.000001,amplitude))
            return min(1,max(0,(db+70)/60))
        }
    }
}


func checkEqualizerAudio() throws -> [String:Any] {
    func rms(frequency:Double,settings:EqualizerSettings) throws -> Float {
        let audio=AVAudioEngine(),player=AVAudioPlayerNode(),eq=AVAudioUnitEQ(numberOfBands:10)
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let input=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48000)!
        input.frameLength=48000
        for i in 0..<48000 {input.floatChannelData![0][i]=Float(sin(2*Double.pi*frequency*Double(i)/48000))*0.1}
        audio.attach(player);audio.attach(eq);audio.connect(player,to:eq,format:format);audio.connect(eq,to:audio.mainMixerNode,format:format)
        settings.apply(to:eq)
        try audio.enableManualRenderingMode(.offline,format:format,maximumFrameCount:4096)
        try audio.start();player.scheduleBuffer(input);player.play()
        let output=AVAudioPCMBuffer(pcmFormat:audio.manualRenderingFormat,frameCapacity:4096)!
        var total:Double=0,count=0,attempts=0
        while audio.manualRenderingSampleTime<48000 && attempts<40 {
            attempts+=1;let frames=min(4096,AVAudioFrameCount(48000-audio.manualRenderingSampleTime))
            if try audio.renderOffline(frames,to:output) == .success {
                if audio.manualRenderingSampleTime>8192 {for i in 0..<Int(output.frameLength) {let v=Double(output.floatChannelData![0][i]);total+=v*v;count+=1}}
            }
        }
        audio.stop();guard count>0 else {throw NSError(domain:"AudioChecks",code:1)}
        return Float(sqrt(total/Double(count)))
    }
    let flat=EqualizerSettings()
    var boost=flat;boost.gains[5]=9
    var cut=flat;cut.gains[5] = -9
    var bypass=boost;bypass.enabled=false
    var preamp=flat;preamp.preamp = -6
    let baseline=try rms(frequency:1000,settings:flat)
    let gain=20*log10(try rms(frequency:1000,settings:boost)/baseline)
    let attenuation=20*log10(try rms(frequency:1000,settings:cut)/baseline)
    let bypassGain=20*log10(try rms(frequency:1000,settings:bypass)/baseline)
    let preampGain=20*log10(try rms(frequency:1000,settings:preamp)/baseline)
    let distant=20*log10(try rms(frequency:100,settings:boost)/rms(frequency:100,settings:flat))
    let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!,buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:2048)!
    buffer.frameLength=2048
    for i in 0..<2048 {buffer.floatChannelData![0][i]=Float(sin(2*Double.pi*1000*Double(i)/48000))*0.2}
    let analyser=SpectrumAnalyser()
    // The first buffer is eligible immediately, independent of any wall-clock wait.
    let spectrum=analyser.analyse(buffer) ?? []
    let peak=spectrum.enumerated().max(by:{$0.element<$1.element})?.offset ?? -1
    let expected=Int(log(1000.0/30)/log(600)*37)
    let stereoFormat=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
    let stereo=AVAudioPCMBuffer(pcmFormat:stereoFormat,frameCapacity:2048)!;stereo.frameLength=2048
    for i in 0..<2048 {let value=buffer.floatChannelData![0][i];stereo.floatChannelData![0][i]=value;stereo.floatChannelData![1][i] = -value}
    let opposed=SpectrumAnalyser().analyse(stereo) ?? []
    let stereoPassed=opposed.count==37 && zip(spectrum,opposed).allSatisfy {abs($0-$1)<0.001}
    let passed=stereoPassed && abs(gain-9)<0.3 && abs(attenuation+9)<0.3 && abs(bypassGain)<0.1 && abs(preampGain+6)<0.1 && abs(distant)<1 && spectrum.count==37 && abs(peak-expected)<=1 && (spectrum.max() ?? 0)>0.5
    return ["passed":passed,"boostDB":gain,"cutDB":attenuation,"bypassDB":bypassGain,"preampDB":preampGain,"distantBandDB":distant,"spectrumPeakBand":peak,"expectedPeakBand":expected,"speakerOutput":false,"opposedStereoSpectrum":stereoPassed]
}

@MainActor func checkLocalAudio(directory:URL) async throws -> [String:Any] {
    let urls=try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).sorted {$0.lastPathComponent<$1.lastPathComponent}
    var formats:[[String:Any]]=[]
    for url in urls {
        let file=try AVAudioFile(forReading:url)
        let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:4096)!
        try file.read(into:buffer)
        let samples=buffer.floatChannelData.map {Array(UnsafeBufferPointer(start:$0[0],count:Int(buffer.frameLength)))} ?? []
        let energy=samples.reduce(0.0) {$0+Double($1*$1)}
        formats.append(["file":url.lastPathComponent,"duration":Double(file.length)/file.processingFormat.sampleRate,"nonzeroDecodedSamples":energy>0.01,"sampleRate":file.processingFormat.sampleRate])
    }
    let eq=try checkEqualizerAudio()
    let local=LocalAudioEngine();local.mute(true)
    var failed=false,cleared=false,recovered=false,frames=0
    local.onError={_ in failed=true};local.onState={s in if !s.hasSource {cleared=true};if s.hasSource && !s.paused && s.time>0.05 {recovered=true}}
    local.onSpectrum={s in if (s.max() ?? 0)>0.02 {frames+=1}}
    let bad=directory.appendingPathComponent("missing.wav");local.open(bad)
    guard let first=urls.first else {throw MusicError.message("Немає тестових файлів.")}
    local.open(first)
    try await Task.sleep(nanoseconds:400_000_000)
    local.shutdown()
    let coordinator=MusicEngine();coordinator.mute(true)
    var continued=false
    coordinator.onState={state in if state.hasSource && state.muted && !state.paused && state.time>0.3 {continued=true}}
    coordinator.playLocal(first);try await Task.sleep(nanoseconds:200_000_000)
    await coordinator.installSession(SessionCredentials(cookie:"SAPISID=synthetic",authUser:"0",pageID:nil),preserveLocal:true)
    try await Task.sleep(nanoseconds:300_000_000)
    let localPreserved=coordinator.isLocal && continued;coordinator.shutdown()
    let passed=localPreserved && formats.count>=5 && formats.allSatisfy {$0["nonzeroDecodedSamples"] as? Bool==true} && eq["passed"] as? Bool==true && failed && cleared && recovered && frames>0
    return ["passed":passed,"sessionRestorePreservesLocalPlayback":localPreserved,"formats":formats,"equalizer":eq,"missingFileReported":failed,"missingFileClearedSource":cleared,"validFileAfterError":recovered,"nonzeroSpectrumFrames":frames,"speakerOutput":false]
}
