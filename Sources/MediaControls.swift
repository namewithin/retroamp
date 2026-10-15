import AppKit
import MediaPlayer

@MainActor final class MediaControls {
    enum Action {case play,pause,toggle,next,previous,stop,seek(Double)}
    var onAction:((Action)->Bool)?
    private let center=MPRemoteCommandCenter.shared()
    private var targets:[(MPRemoteCommand,Any)]=[]
    private(set) var active=false
    init() {
        bind(center.playCommand,.play);bind(center.pauseCommand,.pause);bind(center.togglePlayPauseCommand,.toggle)
        bind(center.nextTrackCommand,.next);bind(center.previousTrackCommand,.previous);bind(center.stopCommand,.stop)
        let command=center.changePlaybackPositionCommand
        let target=command.addTarget { [weak self] event in
            guard let e=event as? MPChangePlaybackPositionCommandEvent else {return .commandFailed}
            let seconds=e.positionTime
            return self?.dispatch(.seek(seconds)) ?? .commandFailed
        };targets.append((command,target));setEnabled(false)
    }
    private func bind(_ command:MPRemoteCommand,_ action:Action) {
        let target=command.addTarget { [weak self] _ in self?.dispatch(action) ?? .commandFailed };targets.append((command,target))
    }
    // MediaPlayer can invoke handlers off the main thread; AppKit/engine actions stay on main.
    nonisolated private func dispatch(_ action:Action)->MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {return MainActor.assumeIsolated {handle(action)}}
        return DispatchQueue.main.sync {MainActor.assumeIsolated {handle(action)}}
    }
    func handle(_ action:Action)->MPRemoteCommandHandlerStatus {
        guard active,onAction?(action)==true else {return .noSuchContent}
        return .success
    }
    private struct Presentation:Equatable {
        let title:String,artist:String
        let duration:Double
        let paused:Bool,canNext:Bool,canPrevious:Bool,canSeek:Bool
    }
    private var published:Presentation?
    private var publishedPosition=0.0,publishedAt=0.0
    private(set) var publicationCount=0
    func update(item:MusicItem?,state:PlaybackState?,canNext:Bool,canPrevious:Bool) {
        guard let item,let state,state.hasSource else {clear();return}
        let value=Presentation(title:state.ad ? "Реклама · YouTube Music":item.title,artist:item.subtitle,duration:state.duration,paused:state.paused,canNext:canNext,canPrevious:canPrevious,canSeek:state.duration>0 && !state.ad)
        let now=ProcessInfo.processInfo.systemUptime,elapsed=now-publishedAt
        let predicted=publishedPosition+(published?.paused==false ? elapsed:0)
        // macOS advances elapsed time from playbackRate; publish transitions/seeks immediately.
        guard published != value || abs(state.time-predicted)>0.25 || (!state.paused && elapsed>=1) else {return}
        if !active {active=true;setEnabled(true)}
        if published?.canNext != value.canNext {center.nextTrackCommand.isEnabled=canNext}
        if published?.canPrevious != value.canPrevious {center.previousTrackCommand.isEnabled=canPrevious}
        if published?.canSeek != value.canSeek {center.changePlaybackPositionCommand.isEnabled=value.canSeek}
        MPNowPlayingInfoCenter.default().nowPlayingInfo=[MPMediaItemPropertyTitle:value.title,MPMediaItemPropertyArtist:value.artist,MPMediaItemPropertyPlaybackDuration:state.duration,MPNowPlayingInfoPropertyElapsedPlaybackTime:state.time,MPNowPlayingInfoPropertyPlaybackRate:state.paused ? 0.0:1.0,MPNowPlayingInfoPropertyDefaultPlaybackRate:1.0]
        MPNowPlayingInfoCenter.default().playbackState=state.paused ? .paused:.playing
        published=value;publishedAt=now;publishedPosition=state.time;publicationCount+=1
    }
    private func setEnabled(_ enabled:Bool) {for (command,_) in targets {command.isEnabled=enabled}}
    func clear() {guard active || published != nil else {return};published=nil;active=false;setEnabled(false);MPNowPlayingInfoCenter.default().nowPlayingInfo=nil;MPNowPlayingInfoCenter.default().playbackState = .stopped}
    func shutdown() {clear();for (command,target) in targets {command.removeTarget(target)};targets=[]}
}
