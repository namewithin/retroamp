import AppKit

// Transparent native buttons retain keyboard/accessibility activation over the drawn display.
final class DisplayHitControl:NSButton {
    override init(frame:NSRect) {super.init(frame:frame);isBordered=false;title="";setButtonType(.momentaryPushIn)}
    convenience init() {self.init(frame:.zero)}
    required init?(coder:NSCoder) {fatalError()}
    override func draw(_ dirtyRect:NSRect) {}
}

final class MarqueeState {
    private(set) var offset:CGFloat=0
    private var wait:Double=1.5
    private var overflow=false
    private var travelWidth:CGFloat=0
    private var previousViewport:CGFloat=0
    func reset() {offset=0;wait=1.5;overflow=false;travelWidth=0}
    func advance(_ delta:Double) {
        guard overflow else {return}
        if wait>0 {wait=max(0,wait-delta);return}
        offset+=CGFloat(delta)*24
        if offset>=travelWidth {offset=0;wait=1.5}
    }
    func draw(_ value:String,in rect:NSRect,size:CGFloat,color:NSColor) {
        guard let font=drawingFont(size:size,bold:false) else {return}
        let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:color]
        let width=ceil((value as NSString).size(withAttributes:attributes).width)
        if previousViewport != rect.width {reset();previousViewport=rect.width}
        overflow=width>rect.width
        travelWidth=width+32
        if !overflow {offset=0;wait=1.5}
        NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:rect).addClip()
        (value as NSString).draw(at:NSPoint(x:rect.minX-offset,y:rect.minY),withAttributes:attributes)
        if overflow,offset>32 {(value as NSString).draw(at:NSPoint(x:rect.minX-offset+travelWidth,y:rect.minY),withAttributes:attributes)}
        NSGraphicsContext.restoreGraphicsState()
    }
}

extension MetalButton {
    func drawIcon(_ role:String)->Bool {
        let known=["previous","play","pause","stop","next","openFiles","close","eqClose","playlistClose","minimize","more","pin"]
        guard known.contains(role) else {return false}
        let w=min(12,max(5,bounds.width-8)),h=min(10,max(5,bounds.height-7))
        let r=NSRect(x:(bounds.width-w)/2,y:(bounds.height-h)/2,width:w,height:h)
        NSColor(calibratedRed:0.16,green:0.18,blue:0.20,alpha:1).setFill()
        func triangle(_ rect:NSRect,right:Bool=true) {
            let p=NSBezierPath();p.move(to:NSPoint(x:right ? rect.minX : rect.maxX,y:rect.minY));p.line(to:NSPoint(x:right ? rect.maxX : rect.minX,y:rect.midY));p.line(to:NSPoint(x:right ? rect.minX : rect.maxX,y:rect.maxY));p.close();p.fill()
        }
        switch role {
        case "play":triangle(r)
        case "previous":NSRect(x:r.minX,y:r.minY,width:2,height:r.height).fill();triangle(NSRect(x:r.minX+3,y:r.minY,width:r.width-3,height:r.height),right:false)
        case "next":triangle(NSRect(x:r.minX,y:r.minY,width:r.width-3,height:r.height));NSRect(x:r.maxX-2,y:r.minY,width:2,height:r.height).fill()
        case "pause":NSRect(x:r.minX+1,y:r.minY,width:3,height:r.height).fill();NSRect(x:r.maxX-4,y:r.minY,width:3,height:r.height).fill()
        case "stop":NSRect(x:bounds.midX-h/2,y:r.minY,width:h,height:h).fill()
        case "openFiles":
            let p=NSBezierPath();p.move(to:NSPoint(x:r.minX,y:r.maxY-3));p.line(to:NSPoint(x:r.midX,y:r.minY));p.line(to:NSPoint(x:r.maxX,y:r.maxY-3));p.close();p.fill();NSRect(x:r.minX,y:r.maxY-2,width:r.width,height:2).fill()
        case "pin":
            let cx=bounds.midX,cy=bounds.midY
            NSRect(x:cx-2.5,y:cy-4,width:5,height:1.5).fill();NSRect(x:cx-1.25,y:cy-2.5,width:2.5,height:3).fill();NSRect(x:cx-3,y:cy,width:6,height:1).fill();NSRect(x:cx-0.5,y:cy+1,width:1,height:3).fill()
        case "minimize":NSRect(x:r.minX,y:r.midY-0.5,width:r.width,height:1).fill()
        case "more":NSRect(x:r.minX,y:r.midY-0.5,width:r.width,height:1).fill();NSRect(x:r.midX-0.5,y:r.minY,width:1,height:r.height).fill()
        default:
            NSColor(calibratedRed:0.16,green:0.18,blue:0.20,alpha:1).setStroke()
            let p=NSBezierPath();p.lineWidth=1.25;p.move(to:NSPoint(x:r.minX,y:r.minY));p.line(to:NSPoint(x:r.maxX,y:r.maxY));p.move(to:NSPoint(x:r.minX,y:r.maxY));p.line(to:NSPoint(x:r.maxX,y:r.minY));p.stroke()
        }
        return true
    }
}
