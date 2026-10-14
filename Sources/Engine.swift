import AppKit

struct PlaybackState {
    let time:Double,duration:Double
    let paused:Bool,ended:Bool,hasSource:Bool,ad:Bool
    let title:String,artist:String,error:String
    let volume:Double
    let muted:Bool
}

// Chromium streams YouTube's own media directly. Audio is never downloaded as a whole track.
@MainActor final class MusicEngine:NSObject {
    var onState:((PlaybackState)->Void)?
    var onError:((String)->Void)?
    var onProgress:((String)->Void)?
    var onSpectrum:(([Float])->Void)?
    private var local:LocalAudioEngine?
    var isLocal:Bool {local != nil}
    private var host=ChromiumHost()
    private var preparationVersion=0
    private var preparation:Task<CDPConnection,Error>?
    private var loadTask:Task<Void,Never>?
    private var pollTask:Task<Void,Never>?
    private var timer:Timer?
    private var session:SessionCredentials?
    private var loadedID:String?
    private var generation=0
    private var wantsPlayback=false
    private var stopped=false
    private var mutedValue=false
    private var volumeValue=0.15
    private var settings=EqualizerSettings.load()
    private var loadingSince:Date?
    private var loadingDeadline:Date?
    private var firstSignal=false
    private var hasSourceValue=false
    private var endedValue=false
    private var failed=false
    var lastStartupSeconds:Double?
    var lastMediaSignalSeconds:Double?
    override init() {
        super.init()
        timer=Timer.scheduledTimer(withTimeInterval:0.08,repeats:true) {[weak self] _ in MainActor.assumeIsolated {self?.poll()}}
    }
    func warm() {Task { [weak self] in _=try? await self?.prepare()}}
    private func prepare() async throws -> CDPConnection {
        if let c=host.connection,!c.isOpen {resetBackend()}
        if let preparation {return try await preparation.value}
        let candidate=session,currentHost=host
        preparationVersion+=1;let version=preparationVersion
        let task=Task { @MainActor in
            let c=try await currentHost.start(script:Self.script)
            try Task.checkCancellation()
            if let cookies=candidate?.browserCookies {
                _=try await c.call("Network.setCookies",["cookies":cookies.map(\.parameters)])
            }
            let query=candidate.flatMap {$0.browserCookies != nil ? "?authuser="+$0.authUser : nil} ?? ""
            _=try await c.call("Page.navigate",["url":"https://music.youtube.com/"+query])
            return c
        }
        preparation=task
        do {return try await task.value} catch {if version==preparationVersion {preparation=nil};throw error}
    }
    func installSession(_ value:SessionCredentials?,preserveLocal:Bool=false) async {
        let keepingLocal=preserveLocal && local != nil
        if !keepingLocal {local?.shutdown();local=nil}
        generation+=1;loadTask?.cancel();loadTask=nil;pollTask?.cancel();pollTask=nil
        preparationVersion+=1;preparation?.cancel();preparation=nil;host.close();host=ChromiumHost();session=value;loadedID=nil;wantsPlayback=false;loadingSince=nil;hasSourceValue=false
        if !keepingLocal {onSpectrum?(Array(repeating:0,count:37));warm()}
    }
    func playLocal(_ url:URL) {
        generation+=1;loadTask?.cancel();loadTask=nil;pollTask?.cancel();pollTask=nil;loadedID=nil;loadingSince=nil;resetBackend()
        if local==nil {
            let engine=LocalAudioEngine();local=engine
            engine.onState={ [weak self] state in guard self?.isLocal==true else {return};self?.onState?(state) }
            engine.onSpectrum={ [weak self] levels in guard self?.isLocal==true else {return};self?.onSpectrum?(levels) }
            engine.onError={ [weak self] error in self?.onError?(error) }
        }
        local?.volume(volumeValue);local?.mute(mutedValue);local?.equalizerSettings(settings);local?.open(url)
    }
    func play(_ id:String) {
        if let local {local.shutdown();self.local=nil;loadedID=nil}

        guard id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else {onError?("Некоректний ідентифікатор треку.");return}
        if loadedID==id,hasSourceValue,loadingSince==nil,host.connection != nil {restart();return}
        generation+=1;let token=generation;loadTask?.cancel();pollTask?.cancel();pollTask=nil;loadedID=id;hasSourceValue=false;endedValue=false;failed=false;wantsPlayback=true;stopped=false;loadingSince=Date();loadingDeadline=Date().addingTimeInterval(30);firstSignal=false;lastStartupSeconds=nil;lastMediaSignalSeconds=nil
        onProgress?("БУФЕРИЗАЦІЯ ПОТОКУ…")
        loadTask=Task { [weak self] in
            guard let self else {return}
            do {
                let c=try await prepare();try Task.checkCancellation();guard token==generation else {return}
                let encoded=Self.json(id)
                let result=try await c.evaluate("(()=>{const p=document.querySelector('#movie_player');if(typeof p?.loadVideoById==='function'){p.loadVideoById(\(encoded));return {loaded:true}}return {loaded:false}})()")
                try Task.checkCancellation();guard token==generation else {return}
                if result["loaded"] as? Bool != true {
                    let query=session.flatMap {$0.browserCookies != nil ? "&authuser="+$0.authUser : nil} ?? ""
                    _=try await c.call("Page.navigate",["url":"https://music.youtube.com/watch?v="+id+query])
                }
                try Task.checkCancellation();guard token==generation else {return};loadTask=nil
            } catch {
                guard !Task.isCancelled,token==generation else {return}
                loadingSince=nil;loadTask=nil;wantsPlayback=false;failed=true;hasSourceValue=false
                if !cIsOpen {resetBackend()};onError?(error.localizedDescription)
            }
        }
    }
    func equalizerSettings(_ value:EqualizerSettings) {settings=value;local?.equalizerSettings(value)}
    func volume(_ value:Double) {volumeValue=min(1,max(0,value));local?.volume(volumeValue)}
    func mute(_ value:Bool) {mutedValue=value;local?.mute(value)}
    func resume() {if let local {local.resume();return};if endedValue {restart();return};wantsPlayback=true;stopped=false;if !hasSourceValue,loadTask==nil,loadingSince==nil,let id=loadedID {play(id)}}
    func pause() {if let local {local.pause();return};wantsPlayback=false;onSpectrum?(Array(repeating:0,count:37))}
    func stop() {if let local {local.stop();return};wantsPlayback=false;stopped=true;action("window.__retroamp?.stop()")}
    func restart() {if let local {local.restart();return};endedValue=false;wantsPlayback=true;stopped=false;action("window.__retroamp?.restart()")}
    func seek(_ fraction:Double) {if let local {local.seek(fraction);return};action("window.__retroamp?.seek(\(min(1,max(0,fraction))))")}
    private func action(_ expression:String) {guard let c=host.connection else {return};Task {_=try? await c.evaluate(expression+";({})")}}
    private func poll() {
        guard local==nil,!failed,pollTask==nil,loadedID != nil,let c=host.connection else {return}
        let token=generation
        let config:[String:Any]=["id":loadedID!,"playing":wantsPlayback,"stopped":stopped,"volume":volumeValue,"muted":mutedValue,"enabled":settings.enabled,"preamp":settings.preamp,"gains":settings.gains]
        let json=Self.json(config)
        pollTask=Task { [weak self] in
            guard let self else {return};defer {if token==generation {pollTask=nil}}
            do {
                let state=try await c.evaluate(Self.script+";window.__retroamp.tick(\(json))")
                guard !Task.isCancelled,token==generation else {return}
                if let error=state["error"] as? String,!error.isEmpty {wantsPlayback=false;loadingSince=nil;failed=true;hasSourceValue=false;onError?(error);return}
                let valid=state["hasSource"] as? Bool==true
                hasSourceValue=valid;endedValue=state["ended"] as? Bool ?? false
                let ad=state["ad"] as? Bool==true
                if ad,loadingSince != nil {loadingDeadline=Date().addingTimeInterval(30)}
                let samples=state["spectrum"] as? [Double] ?? []
                let levels=(samples.count==37 ? samples : Array(repeating:0,count:37)).map(Float.init)
                if valid,lastMediaSignalSeconds==nil,(levels.max() ?? 0)>0.02 {lastMediaSignalSeconds=loadingSince.map {Date().timeIntervalSince($0)}}
                if valid,!firstSignal,!ad,(levels.max() ?? 0)>0.02 {
                    firstSignal=true;lastStartupSeconds=loadingSince.map {Date().timeIntervalSince($0)};loadingSince=nil
                }
                if loadingSince != nil,let deadline=loadingDeadline,Date()>deadline,!ad {loadingSince=nil;wantsPlayback=false;failed=true;hasSourceValue=false;onError?("YouTube довго не відповідає. Натисніть ▶, щоб повторити.")}
                onSpectrum?(wantsPlayback && valid ? levels : Array(repeating:0,count:37))
                onState?(PlaybackState(time:stopped ? 0 : state["time"] as? Double ?? 0,duration:state["duration"] as? Double ?? 0,paused:state["paused"] as? Bool ?? !wantsPlayback,ended:state["ended"] as? Bool ?? false,hasSource:valid,ad:ad,title:"",artist:"",error:"",volume:volumeValue,muted:mutedValue))
            } catch {if !Task.isCancelled,token==generation {wantsPlayback=false;hasSourceValue=false;failed=true;loadingSince=nil;resetBackend();onError?("Потоковий рушій не відповідає. Натисніть ▶ для повтору.")}}
        }
    }
    private var cIsOpen:Bool {host.connection?.isOpen==true}
    private func resetBackend() {preparationVersion+=1;preparation?.cancel();preparation=nil;host.close();host=ChromiumHost()}
    func checkEndTrack() {action("(()=>{const v=document.querySelector('video');if(v&&Number.isFinite(v.duration))window.__retroamp.seek(1-.15/v.duration)})()")}
    func checkDisconnect() {guard let c=host.connection else {return};Task {_=try? await c.call("Browser.close")}}
    func shutdown() {local?.shutdown();local=nil;timer?.invalidate();timer=nil;generation+=1;loadTask?.cancel();pollTask?.cancel();preparation?.cancel();host.close()}
    func checkAudio() async throws -> [String:Any] {
        let c=try await host.start(script:Self.script)
        _=try await c.evaluate(Self.script+";({})")
        return try await c.evaluate(#"""
        (async()=>{
          async function measure(gain,enabled=true,preamp=0,hz=1000){
            const sr=48000,c=new OfflineAudioContext(2,sr,sr),b=c.createBuffer(2,sr,sr);
            for(let i=0;i<sr;i++){const x=.1*Math.sin(2*Math.PI*hz*i/sr);b.getChannelData(0)[i]=x;b.getChannelData(1)[i]=-x}
            const source=c.createBufferSource();source.buffer=b;const g=window.__retroamp.graph(c,source);
            const gains=Array(10).fill(0);gains[5]=gain;g.apply({enabled,preamp,gains,muted:false,volume:1});source.start();
            const out=await c.startRendering();let power=0,opposed=0;
            for(let i=sr/2;i<sr;i++){power+=out.getChannelData(0)[i]**2;opposed=Math.max(opposed,Math.abs(out.getChannelData(0)[i]+out.getChannelData(1)[i]))}
            return {db:20*Math.log10(Math.sqrt(power/(sr/2))/(.1/Math.sqrt(2))),opposed};
          }
          const boost=await measure(9),cut=await measure(-9),bypass=await measure(9,false),pre=await measure(0,true,-6),distant=await measure(9,true,0,100);
          return {passed:Math.abs(boost.db-9)<.3&&Math.abs(cut.db+9)<.3&&Math.abs(bypass.db)<.1&&Math.abs(pre.db+6)<.1&&Math.abs(distant.db)<1&&boost.opposed<.00001,
            boostDB:boost.db,cutDB:cut.db,bypassDB:bypass.db,preampDB:pre.db,distantBandDB:distant.db,opposedStereoPreserved:boost.opposed<.00001,speakerOutput:false,graph:'production WebAudio graph'};
        })()
        """#)
    }
    static func json(_ value:Any)->String {String(decoding:(try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed])) ?? Data("null".utf8),as:UTF8.self)}
    static let script = #"""
    (()=>{
      if(window.__retroamp)return;
      function graph(c,source){
        const pre=c.createGain(),filters=[31,63,125,250,500,1000,2000,4000,8000,16000].map(f=>{const n=c.createBiquadFilter();n.type='peaking';n.frequency.value=f;n.Q.value=1.414;return n});
        source.connect(pre);let tail=pre;for(const n of filters){tail.connect(n);tail=n}
        const master=c.createGain();master.gain.value=0;tail.connect(master);master.connect(c.destination);
        const split=c.createChannelSplitter(2),analysers=[c.createAnalyser(),c.createAnalyser()];tail.connect(split);
        analysers.forEach((a,i)=>{a.fftSize=2048;a.smoothingTimeConstant=.65;split.connect(a,i)});
        return {c,pre,filters,master,analysers,apply(s){pre.gain.setTargetAtTime(s.enabled?10**(s.preamp/20):1,c.currentTime,.02);filters.forEach((n,i)=>n.gain.setTargetAtTime(s.enabled?s.gains[i]:0,c.currentTime,.02));master.gain.setTargetAtTime(s.muted?0:s.volume,c.currentTime,.01)}};
      }
      let v=null,g=null,lastID='',hasPlayed=false,lastTime=0,endedID='',lastDuration=0;
      document.addEventListener('play',e=>{if(e.target instanceof HTMLMediaElement&&!g)e.target.muted=true},true);
      document.addEventListener('ended',e=>{if(e.target===v&&hasPlayed&&!document.querySelector('#movie_player.ad-showing')&&Math.abs(v.duration-lastDuration)<1)endedID=lastID},true);
      window.__retroamp={graph,
        stop(){endedID='';if(v){v.pause();if(!document.querySelector('#movie_player.ad-showing'))v.currentTime=0}},restart(){endedID='';hasPlayed=false;lastTime=0;const p=document.querySelector('#movie_player');if(p?.getVideoData?.().video_id!==lastID&&typeof p?.loadVideoById==='function')p.loadVideoById(lastID);else if(v){v.currentTime=0;v.play().catch(()=>{})}},
        seek(f){if(v&&!document.querySelector('#movie_player.ad-showing')&&Number.isFinite(v.duration)){v.currentTime=f*v.duration;lastTime=v.currentTime;lastDuration=v.duration}},
        tick(s){
          const p=document.querySelector('#movie_player'),candidate=document.querySelector('video'),ad=!!p?.classList.contains('ad-showing'),data=p?.getVideoData?.()||{};
          if(s.id!==lastID){lastID=s.id;hasPlayed=false;lastTime=0;endedID=''}
          const error=document.querySelector('.ytp-error-content-wrap')?.innerText?.trim();
          if(error)return {error:'YouTube: '+error.slice(0,180)};
          if(!candidate)return {};
          if(candidate!==v){v=candidate;g=null}
          if(endedID===s.id&&!s.stopped){v.pause();return {time:lastDuration,duration:lastDuration,paused:true,ended:true,hasSource:true,ad:false,spectrum:[]}}
          if(!ad&&data.video_id&&data.video_id!==s.id&&hasPlayed&&lastDuration>0&&lastTime>=lastDuration-2){endedID=s.id;v.pause();return {time:lastDuration,duration:lastDuration,paused:true,ended:true,hasSource:true,ad:false,spectrum:[]}}
          const matching=ad||data.video_id===s.id;
          if(!matching){v.pause();return {}}
          if(!g&&v.currentSrc&&v.readyState>=2){const c=new AudioContext();g=graph(c,c.createMediaElementSource(v))}
          if(g){g.apply(s);v.muted=false;v.volume=1;if(s.playing)g.c.resume().catch(()=>{})}
          else {v.muted=true}
          const actuallyEnded=!ad&&hasPlayed&&v.ended;
          if(s.stopped){v.pause();if(!ad&&v.currentTime!==0)v.currentTime=0}
          else if(s.playing&&!actuallyEnded){if(v.paused)v.play().catch(()=>{})}else {v.pause()}
          if(!ad&&v.currentTime>.2){hasPlayed=true;lastTime=v.currentTime;lastDuration=v.duration}
          const spectrum=[];
          if(g){const bins=g.analysers.map(a=>{const x=new Float32Array(a.frequencyBinCount);a.getFloatFrequencyData(x);return x}),hz=g.c.sampleRate/2048;
            for(let i=0;i<37;i++){const lo=Math.max(1,Math.floor(35*(16000/35)**(i/37)/hz)),hi=Math.min(bins[0].length-1,Math.max(lo,Math.ceil(35*(16000/35)**((i+1)/37)/hz)));let power=0;
              for(let k=lo;k<=hi;k++)power=Math.max(power,(10**(bins[0][k]/10)+10**(bins[1][k]/10))/2);
              spectrum.push(Math.max(0,Math.min(1,(10*Math.log10(power||1e-12)+85)/75)))}
          }
          return {time:Number.isFinite(v.currentTime)?v.currentTime:0,duration:Number.isFinite(v.duration)?v.duration:0,paused:v.paused,ended:actuallyEnded,hasSource:matching&&v.readyState>=2,ad,spectrum,context:g?.c.state};
        }
      };
    })();
    """#
}
