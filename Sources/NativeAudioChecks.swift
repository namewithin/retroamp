import Foundation
import AVFoundation

func pcm(_ count:AVAudioFrameCount,_ interleaved:Bool=false)->AVAudioPCMBuffer {let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:interleaved)!;let b=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:count)!;b.frameLength=count;return b}
func nativeAudioChecks()throws->[String:Any] {
 var checks:[String:Bool]=[:]
 do{let ring=ring_create(8)!;defer{ring_destroy(ring)};let input=pcm(6,true),out=pcm(8);let p=input.floatChannelData![0];for i in 0..<6{p[i*2]=Float(i+1);p[i*2+1] = -Float(i+1)}
  checks["interleavedAccepted"] = ring_write(ring,input.audioBufferList)==6
  _=ring_read(ring,4,out.mutableAudioBufferList);checks["stereoOrderPreserved"] = (0..<4).allSatisfy{out.floatChannelData![0][$0]==Float($0+1) && out.floatChannelData![1][$0] == -Float($0+1)}
  _=ring_write(ring,input.audioBufferList);_=ring_read(ring,8,out.mutableAudioBufferList);let expected:[Float]=[5,6,1,2,3,4,5,6];checks["wrapPreservesUnreadFrames"] = (0..<8).allSatisfy{out.floatChannelData![0][$0]==expected[$0]}
  _=ring_read(ring,8,out.mutableAudioBufferList);checks["underrunIsSilence"] = (0..<8).allSatisfy{out.floatChannelData![0][$0]==0 && out.floatChannelData![1][$0]==0} && ring_underruns(ring)>0
  _=ring_write(ring,input.audioBufferList);checks["overflowBounded"] = ring_write(ring,input.audioBufferList)==0 && ring_available(ring)==6 && ring_overflows(ring)==6
 }
 do{let ring=ring_create(4096)!;defer{ring_destroy(ring)};let input=pcm(2048),out=pcm(2048);for i in 0..<2048{input.floatChannelData![0][i]=Float(sin(2*Double.pi*1000*Double(i)/48000)*0.1);input.floatChannelData![1][i] = -input.floatChannelData![0][i]};_=ring_write(ring,input.audioBufferList);_=ring_read(ring,2048,out.mutableAudioBufferList);let levels=SpectrumAnalyser().analyse(out) ?? [];checks["real37BandFFT"] = levels.count==37 && (levels.max() ?? 0)>0.5 && levels.filter{$0>0.9}.count<5 && levels.filter{$0<0.5}.count>20}
 func render(_ gain:Float,_ enabled:Bool=true,_ pre:Float=0,_ sourceGain:Float=1)throws->(Double,Double){let dsp=try NativeDSP(capacity:65536,inputGain:sourceGain);var gains=[Float](repeating:0,count:10);gains[5]=gain;dsp.apply(enabled:enabled,preamp:pre,gains:gains);let input=pcm(48000);for i in 0..<48000{input.floatChannelData![0][i]=Float(0.1*sin(2*Double.pi*1000*Double(i)/48000))/sourceGain;input.floatChannelData![1][i] = -input.floatChannelData![0][i]};_=ring_write(dsp.input,input.audioBufferList);dsp.engine.mainMixerNode.outputVolume=1;try dsp.engine.enableManualRenderingMode(.offline,format:dsp.format,maximumFrameCount:4096);try dsp.engine.start();let out=pcm(4096);var power=0.0,count=0,opposed=0.0
  defer{dsp.stop()}
  for _ in 0..<12{let n=AVAudioFrameCount(min(4096,48000-Int(dsp.engine.manualRenderingSampleTime)));if n==0{break};let status=try dsp.engine.renderOffline(n,to:out);guard status == .success else{throw AudioFailure(message:"Offline render failed")};if dsp.engine.manualRenderingSampleTime>24000{for i in 0..<Int(out.frameLength){let l=Double(out.floatChannelData![0][i]),r=Double(out.floatChannelData![1][i]);power+=l*l;opposed=max(opposed,abs(l+r));count+=1}}}
  guard count>12000 else{throw AudioFailure(message:"Insufficient rendered PCM")};return(20*log10(sqrt(power/Double(count))/(0.1/sqrt(2))),opposed)
 }
 let compensation=try render(0,true,0,100);checks["quietSourceGainRestoresNativeLevel"]=abs(compensation.0)<0.2 && compensation.1<0.00001
 let boost=try render(9),cut=try render(-9),bypass=try render(9,false),pre=try render(0,true,-6)
 checks["nativeEQBoost"]=abs(boost.0-9)<0.5;checks["nativeEQCut"]=abs(cut.0+9)<0.5;checks["nativeBypass"]=abs(bypass.0)<0.2;checks["nativePreamp"]=abs(pre.0+6)<0.3;checks["stereoNotSummedAway"]=boost.1<0.00001
 let tap=ProcessTap();do{try tap.start([],allowSystemAudioCapture:false);checks["permissionGateBeforeHardware"]=false}catch{checks["permissionGateBeforeHardware"]=tap.tap==0 && tap.device==0 && !tap.started}
 let gpuRows=[ProcessAudio(object:7,pid:70,bundle:"com.apple.WebKit.GPU",running:1),ProcessAudio(object:8,pid:71,bundle:"com.apple.WebKit.GPU",running:1)]
 checks["exactGPUOnly"]=ownedGPUProcesses(gpuRows,sourcePID:60,reportedSourcePID:60,reportedGPU:70,hostPID:50).map{$0.object}==[7]
 checks["mismatchedHelperRejected"]=ownedGPUProcesses(gpuRows,sourcePID:60,reportedSourcePID:61,reportedGPU:70,hostPID:50).isEmpty
 checks["consumerNeverCaptured"]=ownedGPUProcesses(gpuRows,sourcePID:60,reportedSourcePID:60,reportedGPU:50,hostPID:50).isEmpty
 checks["passed"]=checks.values.allSatisfy{$0};return checks
}
