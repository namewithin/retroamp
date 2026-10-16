import AppKit

struct PlaybackState:Equatable {
    let time:Double,duration:Double
    let paused:Bool,ended:Bool,hasSource:Bool,ad:Bool
    let title:String,artist:String,error:String
    let volume:Double
    let muted:Bool
}

// WebKit streams YouTube directly; an own-process Core Audio tap feeds native EQ/FFT.
@MainActor final class MusicEngine:NSObject {
    var onState:((PlaybackState)->Void)?
    var onError:((String)->Void)?
    var onProgress:((String)->Void)?
    var onSpectrum:(([Float])->Void)?
    let videoOutput=VideoMirror()
    var onVideoMessage:((String)->Void)?
    var videoVisible=false {didSet {if !videoVisible {videoOutput.update(connection:nil,track:nil);renditionTask?.cancel()}}}
    var resolveVideoRendition:((String) async throws -> VideoRendition?)?
    var onVideoQuality:((VideoQualityState)->Void)?
    var videoQuality=VideoQuality.load()
    private var renditionTask:Task<Void,Never>?
    private var renditionAttempted=false
    private var mediaID:String?
    private var renditionOriginTime=0.0
    private var activeRendition:VideoRendition?
    private var renditionPlaybackTime:Double?
    private var renditionNotice:String?
    private var awaitingRendition=false
    private var awaitingAudioRestore=false

    private var local:LocalAudioEngine?
    var isLocal:Bool {local != nil}
    private var host=WebKitHost()
    private var retiringHosts:[WebKitHost]=[]
    private var terminating=false
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
    private(set) var lastBridgeFailure:String?
    var lastStartupSeconds:Double?
    var lastMediaSignalSeconds:Double?
    private(set) var videoGeometry:[String:Any]=[:]
    override init() {
        super.init()
    }
    private func stopPolling() {timer?.invalidate();timer=nil}
    private func setPollingInterval(_ interval:Double) {
        guard local==nil,loadedID != nil,!failed else {stopPolling();return}
        if timer?.isValid==true,timer?.timeInterval==interval {return}
        stopPolling()
        let t=Timer.scheduledTimer(withTimeInterval:interval,repeats:true) {[weak self] _ in MainActor.assumeIsolated {self?.poll()}}
        t.tolerance=min(0.05,interval/5);timer=t
    }
    private var controlRevision=0
    private func wakePolling() {controlRevision+=1;setPollingInterval(0.08)}
    func warm() {Task { [weak self] in _=try? await self?.prepare()}}
    private func prepare() async throws -> CDPConnection {
        guard !terminating else{throw CancellationError()}
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
            return c
        }
        preparation=task
        do {return try await task.value} catch {if version==preparationVersion {preparation=nil};throw error}
    }
    func installSession(_ value:SessionCredentials?,preserveLocal:Bool=false) async {
        guard !terminating else{return}
        videoOutput.update(connection:nil,track:nil)
        let keepingLocal=preserveLocal && local != nil
        if !keepingLocal {local?.shutdown();local=nil}
        renditionTask?.cancel();renditionTask=nil;mediaID=nil;activeRendition=nil;renditionPlaybackTime=nil;renditionAttempted=false;awaitingRendition=false;awaitingAudioRestore=false;renditionNotice=nil
        generation+=1;loadTask?.cancel();loadTask=nil;pollTask?.cancel();pollTask=nil
        preparationVersion+=1;preparation?.cancel();preparation=nil;retireBackendHost();session=value;loadedID=nil;wantsPlayback=false;loadingSince=nil;hasSourceValue=false
        if !keepingLocal {onSpectrum?(Array(repeating:0,count:37))};stopPolling()
    }
    func playLocal(_ url:URL) {
        guard !terminating else{return}
        videoOutput.update(connection:nil,track:nil);onVideoMessage?("VIDEO доступне для пісень YouTube Music")
        renditionTask?.cancel();renditionTask=nil;mediaID=nil;activeRendition=nil;renditionPlaybackTime=nil;renditionAttempted=false;awaitingRendition=false;awaitingAudioRestore=false;renditionNotice=nil
        generation+=1;loadTask?.cancel();loadTask=nil;pollTask?.cancel();pollTask=nil;loadedID=nil;loadingSince=nil;resetBackend()
        if local==nil {
            let engine=LocalAudioEngine();local=engine
            engine.onState={ [weak self] state in guard self?.isLocal==true else {return};self?.onState?(state) }
            engine.onSpectrum={ [weak self] levels in guard self?.isLocal==true else {return};self?.onSpectrum?(levels) }
            engine.onError={ [weak self] error in self?.onError?(error) }
        }
        local?.volume(volumeValue,publish:false);local?.mute(mutedValue,publish:false);local?.equalizerSettings(settings);local?.open(url)
    }
    private func resolveVideoIfNeeded(kind:String,ad:Bool) {
        guard videoVisible,!ad,!stopped,!endedValue,kind=="MUSIC_VIDEO_TYPE_ATV",!renditionAttempted,renditionTask==nil,mediaID==nil,let id=loadedID,let resolveVideoRendition else {return}
        let token=generation
        renditionTask=Task { [weak self] in
            guard let self else {return}
            defer {if token==generation {renditionTask=nil}}
            do {
                let rendition=try await resolveVideoRendition(id)
                guard !Task.isCancelled,token==generation,videoVisible,!stopped,!endedValue,let c=host.connection else {return}
                renditionAttempted=true
                guard let rendition else {renditionNotice="YouTube Music не надав кліп для цієї пісні";return}
                let args=Self.json(rendition.parameters)
                // Read the position at the actual switch, after any seeks during lookup.
                let switched=try await c.evaluate("window.__retroamp.switchVideo(\(Self.json(id)),\(args))")
                guard token==generation else {return}
                guard switched["switched"] as? Bool==true else {renditionAttempted=false;return}
                renditionOriginTime=switched["time"] as? Double ?? 0
                mediaID=rendition.videoID;activeRendition=rendition;renditionPlaybackTime=nil;awaitingRendition=true;endedValue=false;hasSourceValue=false
                loadingSince=Date();loadingDeadline=Date().addingTimeInterval(20);firstSignal=false
                videoOutput.update(connection:nil,track:nil);renditionNotice=nil
            } catch {
                guard !Task.isCancelled,token==generation else {return}
                renditionAttempted=true;renditionNotice="Не вдалося знайти кліп. Аудіо продовжує грати."
            }
        }
    }
    private func restoreAudioAfterVideoFailure() {
        guard let original=loadedID,mediaID != nil else {return}
        let resumePosition=renditionPlaybackTime.map {activeRendition?.originalTime(for:$0) ?? $0} ?? renditionOriginTime
        mediaID=nil;activeRendition=nil;renditionPlaybackTime=nil;awaitingRendition=false;awaitingAudioRestore=true;hasSourceValue=false;endedValue=false;failed=false
        renditionNotice="Кліп недоступний. Повертаю аудіоверсію."
        loadingSince=Date();loadingDeadline=Date().addingTimeInterval(30);firstSignal=false
        action("window.__retroamp.loadRecording(\(Self.json(original)),\(resumePosition))")
    }
    func play(_ id:String) {
        guard !terminating else{return}
        if let local {local.shutdown();self.local=nil;loadedID=nil}

        guard id.range(of:"^[A-Za-z0-9_-]{11}$",options:.regularExpression) != nil else {onError?("Некоректний ідентифікатор треку.");return}
        if loadedID==id,hasSourceValue,loadingSince==nil,host.connection != nil {restart();return}
        videoOutput.update(connection:nil,track:nil)
        renditionTask?.cancel();renditionTask=nil;renditionAttempted=false;mediaID=nil;activeRendition=nil;renditionPlaybackTime=nil;awaitingRendition=false;awaitingAudioRestore=false;renditionNotice=nil
        generation+=1;let token=generation;loadTask?.cancel();pollTask?.cancel();pollTask=nil;loadedID=id;hasSourceValue=false;endedValue=false;failed=false;wantsPlayback=true;stopped=false;loadingSince=Date();loadingDeadline=Date().addingTimeInterval(30);firstSignal=false;lastStartupSeconds=nil;lastMediaSignalSeconds=nil
        wakePolling()
        onProgress?("БУФЕРИЗАЦІЯ ПОТОКУ…")
        loadTask=Task { [weak self] in
            guard let self else {return}
            do {
                let c=try await prepare();try Task.checkCancellation();guard token==generation else {return};wakePolling()
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
                stopPolling();if !cIsOpen {resetBackend()};onError?(error.localizedDescription)
            }
        }
    }
    func equalizerSettings(_ value:EqualizerSettings) {settings=value;local?.equalizerSettings(value);configureNativeAudio();wakePolling()}
    func volume(_ value:Double) {volumeValue=min(1,max(0,value));local?.volume(volumeValue);configureNativeAudio();wakePolling()}
    func mute(_ value:Bool) {mutedValue=value;local?.mute(value);configureNativeAudio();wakePolling()}
    func resume() {if let local {local.resume();return};if endedValue {restart();return};wantsPlayback=true;stopped=false;wakePolling();if !hasSourceValue,loadTask==nil,loadingSince==nil,let id=loadedID {play(id)}}
    func pause() {if let local {local.pause();return};wantsPlayback=false;wakePolling();onSpectrum?(Array(repeating:0,count:37))}
    func stop() {if let local {local.stop();return};wantsPlayback=false;stopped=true;wakePolling();action("window.__retroamp?.stop()")}
    func restart() {if let local {local.restart();return};endedValue=false;wantsPlayback=true;stopped=false;wakePolling();action("window.__retroamp?.restart()")}
    func rewind() {if let local {local.seek(0);return};if wantsPlayback {restart()}else {seek(0)}}
    func seek(_ fraction:Double) {if let local {local.seek(fraction);return};if endedValue {hasSourceValue=false};endedValue=false;wakePolling();action("window.__retroamp?.seek(\(min(1,max(0,fraction))))")}
    private func action(_ expression:String) {guard let c=host.connection else {return};let token=generation;Task {guard token==self.generation else {return};_=try? await c.evaluate(expression+";({})")}}
    private func configureNativeAudio(){host.connection?.configure(settings:settings,volume:volumeValue,muted:mutedValue,playing:wantsPlayback && !stopped)}
    private func poll() {
        guard local==nil,!failed,loadTask==nil,pollTask==nil,loadedID != nil,let c=host.connection else {return}
        let token=generation
        let controls=controlRevision
        let polledID=mediaID ?? loadedID!
        let config:[String:Any]=["id":polledID,"playing":wantsPlayback,"stopped":stopped,"volume":volumeValue,"muted":mutedValue,"enabled":settings.enabled,"preamp":settings.preamp,"gains":settings.gains,"video":videoVisible,"quality":videoQuality.rawValue]
        let json=Self.json(config)
        pollTask=Task { [weak self] in
            guard let self else {return};defer {if token==generation {pollTask=nil}}
            do {
                configureNativeAudio()
                let state=try await c.evaluate("window.__retroamp?.tick(\(json))||({})")
                guard !Task.isCancelled,token==generation,polledID==(mediaID ?? loadedID) else {return}
                if let error=state["error"] as? String,!error.isEmpty {if mediaID != nil {restoreAudioAfterVideoFailure();return};stopPolling();videoOutput.update(connection:nil,track:nil);onVideoMessage?("Кліп недоступний");wantsPlayback=false;loadingSince=nil;failed=true;hasSourceValue=false;onError?(error);return}
                let valid=state["hasSource"] as? Bool==true
                let hasVideo=(state["videoWidth"] as? Double ?? 0)>0
                videoGeometry=state["videoGeometry"] as? [String:Any] ?? [:]
                onVideoQuality?(VideoQualityState(state:state,requested:videoQuality))
                let kind=state["musicVideoType"] as? String ?? ""
                let ad=state["ad"] as? Bool==true
                if valid,!ad {
                    if mediaID != nil {renditionPlaybackTime=state["time"] as? Double}
                    if awaitingRendition || awaitingAudioRestore || (!wantsPlayback && state["paused"] as? Bool==true) {loadingSince=nil;awaitingRendition=false;awaitingAudioRestore=false}
                    resolveVideoIfNeeded(kind:kind,ad:false)
                }
                videoOutput.setPlaybackActive(state["paused"] as? Bool != true);videoOutput.update(connection:videoVisible && valid && hasVideo ? c:nil,track:videoVisible && valid && hasVideo ? token:nil)
                if videoVisible {onVideoMessage?(videoOutput.lastError ?? (renditionNotice ?? (valid && !hasVideo ? (renditionTask != nil ? "Шукаю кліп цієї пісні…" : "Для цього треку доступне лише аудіо") : !valid ? "Завантажую кліп…" : "Кліп поточної пісні")))}
                hasSourceValue=valid;endedValue=state["ended"] as? Bool ?? false
                if ad,loadingSince != nil {loadingDeadline=Date().addingTimeInterval(30)}
                let levels=c.spectrum
                if valid,lastMediaSignalSeconds==nil,(levels.max() ?? 0)>0.02 {lastMediaSignalSeconds=loadingSince.map {Date().timeIntervalSince($0)}}
                if valid,!firstSignal,!ad,(levels.max() ?? 0)>0.02 {
                    firstSignal=true;lastStartupSeconds=loadingSince.map {Date().timeIntervalSince($0)};loadingSince=nil
                }
                if loadingSince != nil,let deadline=loadingDeadline,Date()>deadline,!ad {if awaitingRendition {restoreAudioAfterVideoFailure();return};loadingSince=nil;wantsPlayback=false;failed=true;hasSourceValue=false;stopPolling();onError?("YouTube довго не відповідає. Натисніть ▶, щоб повторити.")}
                onSpectrum?(wantsPlayback && valid ? levels : Array(repeating:0,count:37))
                onState?(PlaybackState(time:stopped ? 0 : state["time"] as? Double ?? 0,duration:state["duration"] as? Double ?? 0,paused:state["paused"] as? Bool ?? !wantsPlayback,ended:state["ended"] as? Bool ?? false,hasSource:valid,ad:ad,title:"",artist:"",error:"",volume:volumeValue,muted:mutedValue))
                if token==generation {setPollingInterval(!wantsPlayback && state["paused"] as? Bool==true && loadingSince==nil && controls==controlRevision ? 0.5:0.08)}
            } catch {
                guard !Task.isCancelled,token==generation else {return}
                lastBridgeFailure=(error as? CDPFailure)?.diagnostic ?? error.localizedDescription
                if let bridge=error as? CDPFailure,bridge.transient,loadingSince != nil,c.isOpen,let deadline=loadingDeadline,Date()<deadline {return}
                wantsPlayback=false;hasSourceValue=false;failed=true;loadingSince=nil;resetBackend();onError?("Потоковий рушій не відповідає. Натисніть ▶ для повтору.")
            }
        }
    }
    private func retireBackendHost(){
        let previous=host;previous.close();retiringHosts.append(previous);host=WebKitHost()
        Task{@MainActor [self]in if await previous.waitUntilClosed(){retiringHosts.removeAll{$0 === previous}}}
    }
    private var cIsOpen:Bool {host.connection?.isOpen==true}
    private func resetBackend() {stopPolling();videoOutput.update(connection:nil,track:nil);preparationVersion+=1;preparation?.cancel();preparation=nil;retireBackendHost()}
    func checkEndTrack() {action("(()=>{const v=document.querySelector('video');if(v&&Number.isFinite(v.duration))window.__retroamp.seek(1-.15/v.duration)})()")}
    func checkDisconnect() {guard let c=host.connection else {return};Task {_=try? await c.call("Browser.close")}}
    func shutdown() {
        renditionTask?.cancel();renditionTask=nil;videoOutput.update(connection:nil,track:nil);local?.shutdown();local=nil;timer?.invalidate();timer=nil;generation+=1;loadTask?.cancel();pollTask?.cancel();preparation?.cancel();host.close()}
    func checkAudio() async throws -> [String:Any] {try nativeAudioChecks()}
    func beginShutdown(){terminating=true;shutdown()}
    func shutdownStreaming()async->Bool {
        beginShutdown();var safe=await host.waitUntilClosed()
        for previous in retiringHosts{if !(await previous.waitUntilClosed()){safe=false}}
        return safe
    }
    var streamDiagnostics:[String:Any] {
        guard let c=host.connection else{return ["backend":"WebKit","connected":false]}
        var d=c.sourceInfo;d["backend"]="WebKit";d["connected"]=c.isOpen;d["tapStarted"]=c.audio.started;d["nativeOutputVolume"]=c.audio.dsp?.engine.mainMixerNode.outputVolume ?? 0
        if let dsp=c.audio.dsp {d["overflowFrames"]=ring_overflows(dsp.input);d["underrunFrames"]=ring_underruns(dsp.input)}
        return d
    }
    static func json(_ value:Any)->String {String(decoding:(try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed])) ?? Data("null".utf8),as:UTF8.self)}
    func prepareVideoFixture(_ url:URL) async throws -> CDPConnection {
        let c=try await host.start(script:Self.script)
        _=try await c.request("script",["script":Self.script])
        let source=Self.json("data:video/mp4;base64,"+(try Data(contentsOf:url)).base64EncodedString())
        _=try await c.evaluate("(async()=>{document.body.replaceChildren();const holder=document.createElement('div');holder.id='movie_player';const inner=document.createElement('div');inner.className='html5-video-container';const media=document.createElement('video');media.preload='auto';inner.append(media);holder.append(inner);document.body.append(holder);const p=document.getElementById('movie_player'),v=p.querySelector('video');let id='fixture0001';p.getVideoData=()=>({video_id:id});p.getPlayerResponse=()=>({videoDetails:{musicVideoType:'MUSIC_VIDEO_TYPE_OMV'}});p.getAvailableQualityLevels=()=>['hd1080','hd720','auto'];let quality='auto';p.getPlaybackQuality=()=>quality;p.setPlaybackQualityRange=(a,b)=>{quality=a;window.fixtureQuality=[a,b]};p.loadVideoById=value=>{id=typeof value==='string'?value:value.videoId;v.pause();v.currentTime=typeof value==='string'?0:value.startSeconds||0};v.muted=true;v.src=\(source);await new Promise((r,j)=>{v.addEventListener('canplay',r,{once:true});v.addEventListener('error',j,{once:true});setTimeout(()=>j(new Error('fixture timeout')),5000)});return {ready:true}})()")
        preparation=Task {c};return c
    }
    static let script = #"""
    (()=>{
      if(window.__retroamp)return;
      let v=null,lastID='',hasPlayed=false,lastTime=0,endedID='',lastDuration=0;
      const videoCanvas=document.createElement('canvas');let frameKey=null,frameTime=-1,frameVideo=null,frameWidth=0,frameHeight=0;
      function videoFrame(key){
        const media=document.querySelector('video'),p=document.getElementById('movie_player');
        if(!media||media.readyState<2||media.seeking||!media.videoWidth||(!p?.classList.contains('ad-showing')&&p?.getVideoData?.().video_id!==lastID))return {};
        if(frameKey===key&&frameVideo===media&&frameTime===media.currentTime&&frameWidth===media.videoWidth&&frameHeight===media.videoHeight)return {};
        try {
          const scale=Math.min(1,1920/media.videoWidth,1080/media.videoHeight);const w=Math.round(media.videoWidth*scale),h=Math.round(media.videoHeight*scale);if(videoCanvas.width!==w)videoCanvas.width=w;if(videoCanvas.height!==h)videoCanvas.height=h;
          videoCanvas.getContext('2d',{willReadFrequently:true,alpha:false}).drawImage(media,0,0,videoCanvas.width,videoCanvas.height);
          const data=videoCanvas.toDataURL('image/jpeg',.9).split(',')[1];frameKey=key;frameTime=media.currentTime;frameVideo=media;frameWidth=media.videoWidth;frameHeight=media.videoHeight;
          return {data,width:videoCanvas.width,height:videoCanvas.height,time:frameTime};
        } catch(e){return {error:'Цей кліп не дозволяє показ кадрів у VIDEO. Звук продовжує грати.'}}
      }

      document.addEventListener('ended',e=>{if(e.target===v&&hasPlayed&&!document.querySelector('#movie_player.ad-showing')&&Math.abs(v.duration-lastDuration)<1)endedID=lastID},true);
      let qualityKey='',qualityAttempt=0;
      function qualityState(p,s,ad){
        const levels=p?.getAvailableQualityLevels?.()||[],requested=s.quality||'auto';
        const key=s.id+':'+requested+':'+levels.join(',');
        if(s.video&&s.playing&&!s.stopped&&!ad&&typeof p?.setPlaybackQualityRange==='function'&&(key!==qualityKey||Date.now()-qualityAttempt>4000)){
          qualityKey=key;qualityAttempt=Date.now();
          const selected=requested==='auto'||levels.includes(requested)?requested:'auto';
          try{p.setPlaybackQualityRange(selected,selected)}catch(e){}
        }
        return {quality:p?.getPlaybackQuality?.()||'auto',availableQualities:levels,musicVideoType:p?.getPlayerResponse?.()?.videoDetails?.musicVideoType||''};
      }
      function loadRecording(id,time){const p=document.querySelector('#movie_player');p?.loadVideoById?.({videoId:id,startSeconds:time});document.querySelector('video')?.pause();return {loaded:true}}
      window.__retroamp={videoFrame,releaseVideo(){videoCanvas.width=0;videoCanvas.height=0;frameVideo=null;frameKey=null},loadRecording,
        switchVideo(expected,rendition){
          const p=document.querySelector('#movie_player'),media=document.querySelector('video');
          if(!media||p?.classList.contains('ad-showing')||p?.getVideoData?.().video_id!==expected||media.ended)return {switched:false};
          const time=media.currentTime,segments=rendition.segments||[];
          let mapped=time;
          if(segments.length){const segment=segments.find(s=>time>=s.from&&time<s.from+s.duration)||[...segments].reverse().find(s=>time>=s.from)||segments[0];mapped=Math.max(0,segment.to+Math.min(segment.duration,Math.max(0,time-segment.from)))}
          loadRecording(rendition.id,mapped);return {switched:true,time,mapped};
        },
        stop(){endedID='';if(v){v.pause();if(!document.querySelector('#movie_player.ad-showing'))v.currentTime=0}},restart(){endedID='';hasPlayed=false;lastTime=0;const p=document.querySelector('#movie_player');if(p?.getVideoData?.().video_id!==lastID&&typeof p?.loadVideoById==='function')p.loadVideoById(lastID);else if(v){v.currentTime=0;v.play().catch(()=>{})}},
        seek(f){if(v&&!document.querySelector('#movie_player.ad-showing')&&Number.isFinite(v.duration)){endedID='';v.currentTime=f*v.duration;lastTime=v.currentTime;lastDuration=v.duration}},
        tick(s){
          const p=document.querySelector('#movie_player'),candidate=document.querySelector('video'),ad=!!p?.classList.contains('ad-showing'),data=p?.getVideoData?.()||{};
          if(s.id!==lastID){lastID=s.id;hasPlayed=false;lastTime=0;endedID=''}
          const error=document.querySelector('.ytp-error-content-wrap')?.innerText?.trim();
          if(error)return {error:'YouTube: '+error.slice(0,180)};
          if(!candidate)return {};
          if(candidate!==v){v=candidate}
          if(endedID===s.id&&!s.stopped){v.pause();return {time:lastDuration,duration:lastDuration,paused:true,ended:true,hasSource:true,ad:false,spectrum:[],videoWidth:data.video_id===s.id?v.videoWidth:0}}
          if(!ad&&data.video_id&&data.video_id!==s.id&&hasPlayed&&lastDuration>0&&lastTime>=lastDuration-2){endedID=s.id;v.pause();return {time:lastDuration,duration:lastDuration,paused:true,ended:true,hasSource:true,ad:false,spectrum:[]}}
          const quality=qualityState(p,s,ad);
          const matching=ad||data.video_id===s.id;
          if(!matching){v.pause();return {}}
          const actuallyEnded=!ad&&hasPlayed&&v.ended;
          v.muted=!window.__retroNativePipe;v.volume=window.__retroNativePipe?1:0;
          if(s.stopped){v.pause();if(!ad&&v.currentTime!==0)v.currentTime=0}
          else if(s.playing&&!actuallyEnded){if(v.paused)v.play().catch(()=>{})}else {v.pause()}
          if(!ad&&v.currentTime>.2){hasPlayed=true;lastTime=v.currentTime;lastDuration=v.duration}

          return {time:Number.isFinite(v.currentTime)?v.currentTime:0,duration:Number.isFinite(v.duration)?v.duration:0,paused:v.paused,ended:actuallyEnded,hasSource:matching&&v.readyState>=2,ad,videoWidth:v.videoWidth,videoGeometry:{width:v.videoWidth,height:v.videoHeight},...quality};
        }
      };
    })();
    """#
}
