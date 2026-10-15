import Foundation
import CoreAudio

struct AudioFailure:LocalizedError {let message:String;var errorDescription:String?{message}}
func checked(_ code:OSStatus,_ action:String)throws{if code != noErr{throw AudioFailure(message:"\(action): OSStatus \(code)")}}
func address(_ selector:AudioObjectPropertySelector)->AudioObjectPropertyAddress{AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)}
func scalar<T:BitwiseCopyable>(_ id:AudioObjectID,_ selector:AudioObjectPropertySelector,_ initial:T)throws->T{var a=address(selector),v=initial,n=UInt32(MemoryLayout<T>.size);try checked(AudioObjectGetPropertyData(id,&a,0,nil,&n,&v),"Read audio property");return v}
func stringProperty(_ id:AudioObjectID,_ selector:AudioObjectPropertySelector)throws->String{var a=address(selector),v:Unmanaged<CFString>?,n=UInt32(MemoryLayout<CFString>.size);try checked(AudioObjectGetPropertyData(id,&a,0,nil,&n,&v),"Read audio string");return v?.takeRetainedValue()as String? ?? ""}
struct ProcessAudio:Codable {let object:AudioObjectID,pid:pid_t,bundle:String,running:UInt32}
func audioProcesses()throws->[ProcessAudio]{var a=address(kAudioHardwarePropertyProcessObjectList),n:UInt32=0;try checked(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n),"List audio processes");var ids=[AudioObjectID](repeating:0,count:Int(n)/MemoryLayout<AudioObjectID>.size);try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&a,0,nil,&n,&ids),"Read audio processes");return ids.compactMap{id in guard let pid=try? scalar(id,kAudioProcessPropertyPID,pid_t(0)),let bundle=try? stringProperty(id,kAudioProcessPropertyBundleID)else{return nil};return ProcessAudio(object:id,pid:pid,bundle:bundle,running:(try?scalar(id,kAudioProcessPropertyIsRunningOutput,UInt32(0))) ?? 0)}}
func ownedGPUProcesses(_ processes:[ProcessAudio],sourcePID:pid_t,reportedSourcePID:pid_t?,reportedGPU:pid_t?,hostPID:pid_t)->[ProcessAudio]{
    guard sourcePID>0,reportedSourcePID==sourcePID,let gpu=reportedGPU,gpu>0,gpu != sourcePID,gpu != hostPID else{return []}
    return processes.filter{$0.pid==gpu && $0.bundle=="com.apple.WebKit.GPU" && $0.object != kAudioObjectUnknown}
}
