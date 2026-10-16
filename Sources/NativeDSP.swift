import Foundation
import AVFoundation
import Accelerate

final class NativeDSP {
    let input:OpaquePointer
    let analysed:OpaquePointer
    let engine=AVAudioEngine(),eq=AVAudioUnitEQ(numberOfBands:10)
    let format:AVAudioFormat
    var source:AVAudioSourceNode!
    private var tapInstalled=false
    private let analyser=SpectrumAnalyser()
    private var analysisBuffer:AVAudioPCMBuffer!
    static let frequencies:[Float]=[31,63,125,250,500,1000,2000,4000,8000,16000]
    init(rate:Double=48000,capacity:UInt32=8192,inputGain:Float=1)throws {
        guard rate.isFinite,rate>=8000,rate<=192000,let format=AVAudioFormat(standardFormatWithSampleRate:rate,channels:2),let a=ring_create(capacity),let b=ring_create(capacity)else{throw AudioFailure(message:"Unsupported PCM format or ring capacity")}
        input=a;analysed=b;self.format=format
        analysisBuffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:2048)!
        source=AVAudioSourceNode(format:format){silent,_,n,out in let read=ring_read(a,n,out)
            if inputGain != 1 {var gain=inputGain;for buffer in UnsafeMutableAudioBufferListPointer(out){if let data=buffer.mData?.assumingMemoryBound(to:Float.self){vDSP_vsmul(data,1,&gain,data,1,vDSP_Length(n)*vDSP_Length(buffer.mNumberChannels))}}}
            silent.pointee=ObjCBool(read==0);return noErr}
        engine.attach(source);engine.attach(eq);engine.connect(source,to:eq,format:format);engine.connect(eq,to:engine.mainMixerNode,format:format)
        apply(enabled:true,preamp:0,gains:Array(repeating:0,count:10))
        eq.installTap(onBus:0,bufferSize:2048,format:format){buffer,_ in _=ring_write(b,buffer.audioBufferList)};tapInstalled=true
        engine.mainMixerNode.outputVolume=0
    }
    func apply(enabled:Bool,preamp:Float,gains:[Float]) {
        guard gains.count==10,preamp.isFinite,abs(preamp)<=12,gains.allSatisfy({$0.isFinite && abs($0)<=12})else{return}
        eq.globalGain=enabled ? preamp:0
        for(i,band)in eq.bands.enumerated(){band.filterType = .parametric;band.frequency=min(Self.frequencies[i],Float(format.sampleRate*0.475));band.bandwidth=1;band.gain=enabled ? gains[i]:0;band.bypass = !enabled}
    }
    func start()throws {guard !engine.isRunning else{return};engine.prepare();try engine.start()}
    func stop(){engine.stop()}
    deinit{engine.stop();if tapInstalled{eq.removeTap(onBus:0)};ring_destroy(input);ring_destroy(analysed)}
    func spectrum()->[Float] {
        guard ring_available(analysed)>=2048 else{return Array(repeating:0,count:37)}
        let buffer=analysisBuffer!;buffer.frameLength=2048
        // Discard stale queued analysis frames. Audio itself is never discarded here.
        while ring_available(analysed)>=2048 {_ = ring_read(analysed,2048,buffer.mutableAudioBufferList)}
        return analyser.analyse(buffer) ?? Array(repeating:0,count:37)
    }
}
