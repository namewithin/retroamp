import Foundation
import CoreAudio
import AVFoundation

@available(macOS 14.2,*)
final class ProcessTap {
    private(set)var tap:AudioObjectID=0,device:AudioObjectID=0
    private var io:AudioDeviceIOProcID?
    private(set)var dsp:NativeDSP?
    private(set)var started=false
    func start(_ selected:[ProcessAudio],allowSystemAudioCapture:Bool)throws {
        guard allowSystemAudioCapture else{throw AudioFailure(message:"System audio capture requires explicit approval")}
        guard !selected.isEmpty,Set(selected.map{$0.pid}).count==selected.count,selected.allSatisfy({$0.bundle=="com.apple.WebKit.GPU" && $0.pid != getpid() && $0.object != 0})else{throw AudioFailure(message:"No verified source process")}
        guard tap==0,device==0 else{throw AudioFailure(message:"Tap already exists")}
        // Only explicit process objects from the verified helper's own WKWebView.
        let description=CATapDescription(stereoMixdownOfProcesses:selected.map{$0.object})
        description.name="Retroamp private WebKit source";description.isPrivate=true;description.isExclusive=false;description.muteBehavior = .muted
        if #available(macOS 26.0,*){description.isProcessRestoreEnabled=false}
        try checked(AudioHardwareCreateProcessTap(description,&tap),"Create private process tap")
        do{
            let format=try scalar(tap,kAudioTapPropertyFormat,AudioStreamBasicDescription())
            guard format.mFormatID==kAudioFormatLinearPCM,format.mChannelsPerFrame==2,format.mBitsPerChannel==32,format.mFormatFlags & kAudioFormatFlagIsFloat != 0,format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0 else{throw AudioFailure(message:"Unsupported tap PCM; no format reinterpretation")}
            let uid=try stringProperty(tap,kAudioTapPropertyUID)
            guard !uid.isEmpty else{throw AudioFailure(message:"Missing tap UID")}
            let config:[String:Any]=[kAudioAggregateDeviceNameKey:"Retroamp private tap input",kAudioAggregateDeviceUIDKey:UUID().uuidString,kAudioAggregateDeviceIsPrivateKey:true,kAudioAggregateDeviceTapAutoStartKey:false,kAudioAggregateDeviceTapListKey:[[kAudioSubTapUIDKey:uid,kAudioSubTapDriftCompensationKey:true]]]
            try checked(AudioHardwareCreateAggregateDevice(config as CFDictionary,&device),"Create private tap-only device")
            // No hardware subdevices: neither microphone channels nor default-device changes.
            let processor=try NativeDSP(rate:format.mSampleRate,inputGain:100);dsp=processor
            let ring=processor.input
            try checked(AudioDeviceCreateIOProcIDWithBlock(&io,device,nil){_,input,_,_,_ in _=ring_write(ring,input)},"Create tap callback")
            let current=try audioProcesses()
            guard selected.allSatisfy({row in current.contains{$0.object==row.object && $0.pid==row.pid && $0.bundle==row.bundle}})else{throw AudioFailure(message:"Source process changed before capture")}
            try processor.start() // Output remains zero; only the native EQ output could reach speakers.
            try checked(AudioDeviceStart(device,io),"Start private process tap")
            started=true
        }catch{stop();throw error}
    }
    func stop(){if device != 0{if started{AudioDeviceStop(device,io)};if let io{AudioDeviceDestroyIOProcID(device,io)};AudioHardwareDestroyAggregateDevice(device)};io=nil;device=0;started=false;dsp?.stop();dsp=nil;if tap != 0{AudioHardwareDestroyProcessTap(tap);tap=0}}
    deinit{stop()}
}
