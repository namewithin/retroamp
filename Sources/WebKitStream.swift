import Foundation
import CryptoKit
import Darwin

// Typed transport errors are retained for the existing navigation/retry contract.
enum CDPFailure:LocalizedError {
    case navigation,timeout,script(String)
    var errorDescription:String?{switch self{case .navigation:return "Сторінка YouTube переходить до треку.";case .timeout:return "WebKit не відповів.";case .script:return "Не вдалося виконати дію плеєра."}}
    var transient:Bool{switch self{case .navigation,.timeout:return true;case .script:return false}}
    var diagnostic:String{switch self{case .navigation:return "navigation context replaced";case .timeout:return "WebKit IPC timeout";case .script(let s):return s}}
}

@MainActor final class StreamConnection {
    let process:Process
    let input:Pipe,output:Pipe
    let writer:CommandWriter
    let frames=StreamFrames(),audio=ProcessTap()
    private var nextID=0,pending:[Int:CheckedContinuation<[String:Any],Error>]=[:]
    private var closed=false,quiet=false
    private var cleanup:Task<Bool,Never>?
    private(set)var safeToExit=false
    private var configuring=false
    private(set)var sourceInfo:[String:Any]=[:]
    private var selected:[ProcessAudio]=[]
    private var capturedDocument:Int?
    private var settings=EqualizerSettings(),volume=0.15,muted=false,playing=false
    var isOpen:Bool{!closed && process.isRunning}
    var quietConfirmed:Bool{quiet}
    var spectrum:[Float]{audio.dsp?.spectrum() ?? Array(repeating:0,count:37)}
    init(executable:URL)throws {
        process=Process();input=Pipe();output=Pipe();writer=CommandWriter(input.fileHandleForWriting)
        process.executableURL=executable;process.arguments=["--controlled-stream"];process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler={[weak self,frames]h in
            let data=h.availableData
            let messages=frames.append(data)
            Task{@MainActor [weak self]in guard let self else{return};for value in messages{self.receive(value)};if data.isEmpty{self.close()}}
        }
        try process.run()
    }
    private func receive(_ value:[String:Any]) {
        if value["quiet"]as?Bool==true{quiet=true;return}
        guard let id=value["id"]as?Int,let waiting=pending.removeValue(forKey:id)else{return}
        if let error=value["error"]as?String {
            if error.localizedCaseInsensitiveContains("navigation"){waiting.resume(throwing:CDPFailure.navigation)}else{waiting.resume(throwing:CDPFailure.script(String(error.prefix(220))))}
        }else{waiting.resume(returning:value["result"]as?[String:Any] ?? [:])}
    }
    @inline(never) func request(_ method:String,_ params:[String:Any]=[:])async throws->[String:Any] {
        guard isOpen else{throw MusicError.message("WebKit-джерело закрито.")}
        nextID+=1;let id=nextID;var value=params;value["id"]=id;value["method"]=method
        let watchdog=Task{@MainActor [weak self]in
            try?await Task.sleep(nanoseconds:10_000_000_000)
            if !Task.isCancelled,let waiting=self?.pending.removeValue(forKey:id){waiting.resume(throwing:CDPFailure.timeout)}
        };defer{watchdog.cancel()}
        return try await withCheckedThrowingContinuation{waiting in
            pending[id]=waiting
            if !writer.send(value){pending.removeValue(forKey:id)?.resume(throwing:MusicError.message("Канал WebKit закрито."));close()}
        }
    }
    @inline(never) func evaluate(_ expression:String)async throws->[String:Any] {
        let ticking=expression.contains("window.__retroamp?.tick(")
        let method=expression.hasSuffix(";({})") ? "execute":"evaluate"
        let value=try await request(method,["expression":expression])
        if ticking {
            sourceInfo=try await request("sourceInfo")
            guard isOpen,!Task.isCancelled else{throw CancellationError()}
            if value["hasSource"]as?Bool==true{try await ensureAudio()}

        }
        return value
    }
    func configure(settings:EqualizerSettings,volume:Double,muted:Bool,playing:Bool){
        self.settings=settings;self.volume=volume;self.muted=muted;self.playing=playing
        if let dsp=audio.dsp{settings.apply(to:dsp.eq,sampleRate:dsp.format.sampleRate);dsp.engine.mainMixerNode.outputVolume=muted || !playing ? 0:Float(volume)}
    }
    private func ensureAudio()async throws {
        if audio.started,capturedDocument != sourceInfo["documentGeneration"]as?Int,sourceInfo["guardVerified"]as?Bool==true,sourceInfo["nativePipeActive"]as?Bool != true {
            // A navigation can replace the GPU's audio client without replacing its PID.
            // The new document has confirmed mute/zero volume, so rebuild the exact process tap.
            audio.stop();selected=[]
        }
        if audio.started {
            guard sourceInfo["sourcePID"]as?Int32==process.processIdentifier,sourceInfo["gpuPID"]as?Int32==selected.first?.pid else{close();throw MusicError.message("WebKit змінив аудіопроцес. Повторіть відтворення.")}
            // Hardware format changes can stop AVAudioEngine while the muting tap
            // remains active. Recover on this owned connection's normal poll.
            try audio.dsp?.start()
            if sourceInfo["nativePipeActive"]as?Bool != true,sourceInfo["guardVerified"]as?Bool==true{try await activateCurrentDocument()}
            return
        }
        guard !configuring,sourceInfo["guardVerified"]as?Bool==true else{return}
        let rows=ownedGPUProcesses(try audioProcesses(),sourcePID:process.processIdentifier,reportedSourcePID:sourceInfo["sourcePID"]as?Int32,reportedGPU:sourceInfo["gpuPID"]as?Int32,hostPID:getpid())
        guard rows.count==1 else{return}
        configuring=true;defer{configuring=false}
        try Task.checkCancellation();guard isOpen else{throw CancellationError()}
        // User authorized this own-process system-audio route. macOS still enforces its permission.
        try audio.start(rows,allowSystemAudioCapture:true);selected=rows;capturedDocument=sourceInfo["documentGeneration"]as?Int
        configure(settings:settings,volume:volume,muted:muted,playing:playing)
        try Task.checkCancellation();guard isOpen else{throw CancellationError()}
        try await activateCurrentDocument()
        try Task.checkCancellation();guard isOpen else{throw CancellationError()}
    }
    private func activateCurrentDocument()async throws {
        try Task.checkCancellation();guard isOpen,let token=sourceInfo["documentGeneration"]as?Int else{throw CancellationError()}
        _=try await request("activate",["enabled":true,"documentGeneration":token])
        try Task.checkCancellation();guard isOpen else{throw CancellationError()}
    }
    // Compatibility for existing control/fixture callers; no DevTools or browser TCP port exists.
    func call(_ method:String,_ params:[String:Any]=[:])async throws->[String:Any] {
        switch method {
        case "Network.setCookies":return try await request("cookies",params)
        case "Page.navigate":return try await request("navigate",params)
        case "Browser.close":close();return [:]
        case "Retroamp.cookieInfo":return try await request("cookieInfo")
        default:throw MusicError.message("Непідтримувана дія WebKit: "+method)
        }
    }
    func close(){
        guard !closed else{return};closed=true
        audio.dsp?.engine.mainMixerNode.outputVolume=0
        let waiting=Array(pending.values);pending.removeAll();for item in waiting{item.resume(throwing:MusicError.message("WebKit-джерело закрито."))}
        nextID+=1;writer.send(["id":nextID,"method":"shutdown"]);writer.close()
        cleanup=Task{@MainActor [self]in
            for _ in 0..<25{if !process.isRunning{break};try?await Task.sleep(nanoseconds:40_000_000)}
            if process.isRunning{process.terminate();for _ in 0..<25{if !process.isRunning{break};try?await Task.sleep(nanoseconds:40_000_000)}}
            if process.isRunning{kill(process.processIdentifier,SIGKILL)}
            for _ in 0..<25{if !process.isRunning{break};try?await Task.sleep(nanoseconds:40_000_000)}
            // Revalidate the exact HAL object before signalling a GPU. Never signal a reused PID.
            if !quiet,!selected.isEmpty {
                for signal in [SIGTERM,SIGKILL] {
                    guard let rows=try?audioProcesses()else{return false}
                    if let original=selected.first,rows.contains(where:{$0.object==original.object && $0.pid==original.pid && $0.bundle==original.bundle && $0.running != 0}) {
                        kill(original.pid,signal)
                        for _ in 0..<25 {
                            guard let now=try?audioProcesses()else{return false}
                            if !now.contains(where:{$0.object==original.object && $0.pid==original.pid && $0.bundle==original.bundle && $0.running != 0}){break}
                            try?await Task.sleep(nanoseconds:40_000_000)
                        }
                    }
                }
                guard let rows=try?audioProcesses()else{return false}
                if selected.contains(where:{old in rows.contains{$0.object==old.object && $0.pid==old.pid && $0.bundle==old.bundle && $0.running != 0}}){return false}
            }
            guard !process.isRunning else{return false}
            output.fileHandleForReading.readabilityHandler=nil;audio.stop();safeToExit=true;return true
        }
    }
    @discardableResult func waitUntilClosed()async->Bool {
        close();if await cleanup?.value==true{return true}
        // A source that resisted a previous shutdown may have finished since then.
        if !process.isRunning,let rows=try?audioProcesses(),!selected.contains(where:{old in rows.contains{$0.object==old.object && $0.pid==old.pid && $0.bundle==old.bundle && $0.running != 0}}){audio.stop();safeToExit=true}
        return safeToExit
    }
}

@MainActor final class WebKitHost {
    var connection:StreamConnection?
    private var retiring:[StreamConnection]=[]
    func start(script:String)async throws->StreamConnection {
        if let connection,connection.isOpen{return connection}
        let executable=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Retroamp Source.app/Contents/MacOS/Source")
        let digest=SHA256.hash(data:try Data(contentsOf:executable)).map{String(format:"%02x",$0)}.joined()
        guard digest==streamHelperSHA256 else{throw MusicError.message("Пошкоджений WebKit helper. Перевстановіть Retroamp.")}
        let c=try StreamConnection(executable:executable);connection=c
        do{_=try await c.request("script",["script":script]);try Task.checkCancellation();return c}catch{c.close();throw error}
    }
    func close(){if let connection{connection.close();retiring.append(connection)};connection=nil;retiring.removeAll{$0.safeToExit}}
    func waitUntilClosed()async->Bool{
        close();var safe=true
        for c in retiring{if !(await c.waitUntilClosed()){safe=false}}
        retiring.removeAll{$0.safeToExit};return safe
    }
}
// Retains source compatibility of the existing VIDEO tests; transport is native WebKit IPC.
typealias CDPConnection=StreamConnection
