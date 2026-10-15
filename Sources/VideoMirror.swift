import AppKit

// Copies decoded pictures from the existing media element; never creates or plays media.
@MainActor final class VideoMirror {
    var onFrame:((NSImage?)->Void)?
    var onError:((String)->Void)?
    private var connection:CDPConnection?
    private var track:Int?
    private var revision=0
    private var operation:Task<Void,Never>?
    private(set) var frameCount=0
    private(set) var lastError:String?
    private(set) var isCapturing=false
    private var playbackActive=true
    func setPlaybackActive(_ active:Bool) {
        guard playbackActive != active else {return};playbackActive=active
        if active,lastError==nil {update(connection:connection,track:track,force:true)}
    }
    func update(connection:CDPConnection?,track:Int?,force:Bool=false) {
        guard force || self.connection !== connection || self.track != track else {return}
        let sourceChanged=self.connection !== connection || self.track != track
        let oldConnection=self.connection
        self.connection=connection;self.track=track;revision+=1;let token=revision
        let previous=operation;previous?.cancel()
        lastError=nil;isCapturing=false;if sourceChanged {onFrame?(nil)}
        operation=Task { @MainActor [weak self,weak connection] in
            // Cancelling a Swift task does not cancel a CDP request already awaiting a reply.
            // Keep the chain even for hide requests, then coalesce stale revisions before encoding.
            await previous?.value
            guard !Task.isCancelled,let self,token==self.revision else{return}
            guard let connection,let track,connection.isOpen else {
                if let oldConnection,oldConnection.isOpen{_=try?await oldConnection.evaluate("window.__retroamp.releaseVideo();({})")}
                return
            }
            self.isCapturing=true
            defer {if token==self.revision {self.isCapturing=false}}
            while !Task.isCancelled,connection.isOpen,token==self.revision {
                do {
                    let result=try await connection.evaluate("window.__retroamp?.videoFrame('\(track):\(token)')||({})")
                    guard !Task.isCancelled,token==self.revision else {return}
                    if let error=result["error"] as? String {self.lastError=error;self.onFrame?(nil);self.onError?(error);return}
                    autoreleasepool {if let encoded=result["data"] as? String,let data=Data(base64Encoded:encoded),let image=NSImage(data:data) {image.cacheMode = .never;self.frameCount+=1;self.onFrame?(image)}}
                    try await Task.sleep(nanoseconds:self.playbackActive ? 66_666_667:500_000_000)
                } catch {if !Task.isCancelled,token==self.revision {let message="VIDEO недоступне. Закрийте й відкрийте вікно ще раз.";self.lastError=message;self.onFrame?(nil);self.onError?(message)};return}
            }
        }
    }
}
