import AppKit
import ImageIO
import zlib

// Winamp classic sprite coordinates were checked against Webamp's MIT-licensed
// skinSprites.ts. The application ships no Winamp bitmap assets.
var activeSkin:WSZSkin?
final class WSZSkin {
    let name:String
    private var images:[String:CGImage]=[:]
    private var crops:[String:NSImage]=[:]
    var textColor=green,backgroundColor=NSColor.black,selectionColor=NSColor(calibratedRed:0.05,green:0.12,blue:0.47,alpha:1)
    var spectrumColors:[NSColor]=[]
    init(data:Data,name:String) throws {
        self.name=name
        let entries=try SkinArchive(data:data).files()
        var decodedPixels=0
        for (key,bytes) in entries where key.hasSuffix(".bmp") || key.hasSuffix(".png") {
            guard ["main","eqmain","pledit","cbuttons","shufrep","titlebar","volume","balance","playpaus","monoster","numbers","nums_ex","text","posbar"].contains(key.split(separator:".").dropLast().joined(separator:".")) else {continue}
            guard let source=CGImageSourceCreateWithData(bytes as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=props[kCGImagePropertyPixelWidth] as? Int,let h=props[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=2048,h<=2048,w*h<=2_000_000,let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {throw MusicError.message("Пошкоджене зображення у скіні: \(key)")}
            decodedPixels+=w*h;guard decodedPixels<=8_000_000 else {throw MusicError.message("Завеликі зображення у скіні.")}
            let stem=String(key.split(separator:".").dropLast().joined(separator:"."));if images[stem]==nil || key.hasSuffix(".bmp") {images[stem]=image}
        }
        guard let main=images["main"],main.width>=275,main.height>=116 else {throw MusicError.message("Це не класичний скін Winamp 2: немає main.bmp 275×116.")}
        if let bytes=entries["pledit.txt"],let value=String(data:bytes,encoding:.utf8) ?? String(data:bytes,encoding:.windowsCP1252) {
            for line in value.components(separatedBy:.newlines) {let pair=line.split(separator:"=",maxSplits:1).map {String($0).trimmingCharacters(in:.whitespaces)};if pair.count==2,let color=Self.color(pair[1]) {switch pair[0].lowercased() {case "normal":textColor=color;case "normalbg":backgroundColor=color;case "selectedbg":selectionColor=color;default:break}}}
        }
        if let bytes=entries["viscolor.txt"],let value=String(data:bytes,encoding:.utf8) {
            spectrumColors=value.components(separatedBy:.newlines).compactMap {line in let parts=line.split(separator:",").prefix(3).compactMap {Int($0.trimmingCharacters(in:.whitespaces))};guard parts.count==3,parts.allSatisfy({0...255 ~= $0}) else {return nil};return NSColor(calibratedRed:CGFloat(parts[0])/255,green:CGFloat(parts[1])/255,blue:CGFloat(parts[2])/255,alpha:1)}
        }
    }
    func pixelColor(_ sheet:String,x:Int,y:Int)->NSColor? {guard let image=images[sheet],x<image.width,y<image.height else {return nil};return NSBitmapImageRep(cgImage:image).colorAt(x:x,y:y)}
    private static func color(_ value:String)->NSColor? {
        let hex=value.trimmingCharacters(in:CharacterSet(charactersIn:"# ")).prefix(6)
        guard hex.count==6,let n=UInt32(hex,radix:16) else {return nil}
        return NSColor(calibratedRed:CGFloat((n>>16)&255)/255,green:CGFloat((n>>8)&255)/255,blue:CGFloat(n&255)/255,alpha:1)
    }
    @discardableResult func draw(_ sheet:String,_ source:NSRect,_ destination:NSRect)->Bool {
        let key="\(sheet):\(source)";let sprite:NSImage
        if let cached=crops[key] {sprite=cached} else {
            guard let image=images[sheet],source.minX>=0,source.minY>=0,source.maxX<=CGFloat(image.width),source.maxY<=CGFloat(image.height),let crop=image.cropping(to:source) else {return false}
            sprite=NSImage(cgImage:crop,size:source.size);crops[key]=sprite
        }
        NSGraphicsContext.current?.imageInterpolation = .none
        sprite.draw(in:destination,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil);return true
    }
    func drawMain(in rect:NSRect,selected:Bool) {
        draw("main",NSRect(x:0,y:0,width:275,height:116),rect)
        draw("titlebar",NSRect(x:27,y:selected ? 0 : 15,width:275,height:14),NSRect(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height*14/116))
    }
    func drawEqualizer(in rect:NSRect,selected:Bool)->Bool {
        guard draw("eqmain",NSRect(x:0,y:0,width:275,height:116),rect) else {return false}
        draw("eqmain",NSRect(x:0,y:selected ? 134 : 149,width:275,height:14),NSRect(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height*14/116));return true
    }
    func drawPlaylist(in rect:NSRect,selected:Bool)->Bool {
        guard images["pledit"] != nil else {return false}
        fill(rect,backgroundColor)
        let w=rect.width,h=rect.height,y:CGFloat=selected ? 0 : 21
        for x in stride(from:25.0,to:Double(w-25),by:25) {draw("pledit",NSRect(x:127,y:y,width:25,height:20),NSRect(x:CGFloat(x),y:0,width:min(25,w-25-CGFloat(x)),height:20))}
        draw("pledit",NSRect(x:0,y:y,width:25,height:20),NSRect(x:0,y:0,width:25,height:20));draw("pledit",NSRect(x:153,y:y,width:25,height:20),NSRect(x:w-25,y:0,width:25,height:20));draw("pledit",NSRect(x:26,y:y,width:100,height:20),NSRect(x:(w-100)/2,y:0,width:100,height:20))
        for top in stride(from:20.0,to:Double(h-38),by:29) {let bh=min(29,h-38-CGFloat(top));draw("pledit",NSRect(x:0,y:42,width:12,height:bh),NSRect(x:0,y:CGFloat(top),width:12,height:bh));draw("pledit",NSRect(x:31,y:42,width:20,height:bh),NSRect(x:w-20,y:CGFloat(top),width:20,height:bh))}
        draw("pledit",NSRect(x:0,y:72,width:125,height:38),NSRect(x:0,y:h-38,width:125,height:38));draw("pledit",NSRect(x:126,y:72,width:150,height:38),NSRect(x:w-150,y:h-38,width:150,height:38))
        for x in stride(from:125.0,to:Double(w-150),by:25) {draw("pledit",NSRect(x:179,y:0,width:25,height:38),NSRect(x:CGFloat(x),y:h-38,width:min(25,w-150-CGFloat(x)),height:38))};fill(NSRect(x:12,y:h-48,width:w-32,height:40),pixelColor("pledit",x:1,y:72) ?? backgroundColor);return true
    }
    func button(_ role:String,pressed:Bool,selected:Bool,in rect:NSRect)->Bool {
        let y:CGFloat=pressed ? 18 : 0
        if let i=["previous","play","pause","stop","next"].firstIndex(of:role) {return draw("cbuttons",NSRect(x:CGFloat(i)*23,y:y,width:23,height:18),rect)}
        switch role {
        case "openFiles":return draw("cbuttons",NSRect(x:114,y:pressed ? 16 : 0,width:22,height:16),rect)
        case "shuffle","repeat":return draw("shufrep",NSRect(x:role=="shuffle" ? 28 : 0,y:(selected ? 30 : 0)+(pressed ? 15 : 0),width:role=="shuffle" ? 47 : 28,height:15),rect)
        case "toggleEQ","togglePlaylist":return draw("shufrep",NSRect(x:(role=="toggleEQ" ? 0 : 23)+(pressed ? 46 : 0),y:selected ? 73 : 61,width:23,height:12),rect)
        case "close","minimize":return draw("titlebar",NSRect(x:role=="close" ? 18 : 9,y:pressed ? 9 : 0,width:9,height:9),rect)
        case "playlistClose":return draw("pledit",NSRect(x:52,y:42,width:9,height:9),rect)
        case "eqClose":return draw("eqmain",NSRect(x:0,y:pressed ? 125 : 116,width:9,height:9),rect)
        case "eqOn":return draw("eqmain",NSRect(x:10+(selected ? 59 : 0)+(pressed ? 118 : 0),y:119,width:26,height:12),rect)
        case "eqPreset":return draw("eqmain",NSRect(x:224,y:pressed ? 176 : 164,width:44,height:12),rect)
        default:return false
        }
    }
}

// Read ZIP entries in memory. No paths, executables or cursor files are extracted.
struct SkinArchive {
    let data:Data
    private func word(_ p:Int,_ bytes:Int) throws -> Int {
        guard p>=0,p<=data.count-bytes else {throw MusicError.message("Пошкоджений архів скіна.")}
        return (0..<bytes).reduce(0) {$0 | Int(data[p+$1]) << ($1*8)}
    }
    func files() throws -> [String:Data] {
        guard data.count>=22,data.count<=20_000_000 else {throw MusicError.message("Архів скіна порожній або перевищує 20 MB.")}
        var eocd:Int?
        for p in stride(from:data.count-22,through:max(0,data.count-65_557),by:-1) {if try word(p,4)==0x06054b50,try word(p+20,2)==data.count-p-22 {eocd=p;break}}
        guard let end=eocd,try word(end+4,2)==0,try word(end+6,2)==0 else {throw MusicError.message("Потрібен звичайний ZIP-скін Winamp 2 (.wsz).")}
        let count=try word(end+10,2),directorySize=try word(end+12,4);var p=try word(end+16,4)
        guard count<=256,try word(end+8,2)==count,p<=end-directorySize else {throw MusicError.message("Непідтримуваний архів скіна.")}
        var result:[String:Data]=[:],total=0
        for _ in 0..<count {
            guard try word(p,4)==0x02014b50 else {throw MusicError.message("Пошкоджений каталог ZIP.")}
            let flags=try word(p+8,2),method=try word(p+10,2),crc=try word(p+16,4),compressed=try word(p+20,4),size=try word(p+24,4),nameLength=try word(p+28,2),extra=try word(p+30,2),comment=try word(p+32,2),local=try word(p+42,4)
            guard p<=data.count-46-nameLength-extra-comment,flags & 1 == 0,size<=4_000_000,compressed<=20_000_000 else {throw MusicError.message("Скін містить непідтримувані або завеликі файли.")}
            let filename=String(data:data.subdata(in:p+46..<p+46+nameLength),encoding:.utf8) ?? ""
            p+=46+nameLength+extra+comment
            let key=filename.replacingOccurrences(of:"\\",with:"/").split(separator:"/").last.map(String.init)?.lowercased() ?? ""
            guard key.hasSuffix(".bmp") || key.hasSuffix(".png") || ["pledit.txt","viscolor.txt"].contains(key) else {continue}
            guard result[key]==nil,try word(local,4)==0x04034b50 else {throw MusicError.message("Повторні або пошкоджені файли у скіні.")}
            let start=try local+30+word(local+26,2)+word(local+28,2)
            guard start<=data.count-compressed else {throw MusicError.message("Пошкоджений файл у скіні.")}
            total+=size;guard total<=32_000_000 else {throw MusicError.message("Розпакований скін перевищує 32 MB.")}
            let input=data.subdata(in:start..<start+compressed),output:Data
            if method==0 {guard size==compressed else {throw MusicError.message("Пошкоджений ZIP.")};output=input}
            else if method==8 {
                var buffer=Data(count:max(1,size)),stream=z_stream()
                guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw MusicError.message("Не вдалося розпакувати скін.")}
                defer {inflateEnd(&stream)}
                let status=input.withUnsafeBytes {src in buffer.withUnsafeMutableBytes {dst in
                    stream.next_in=UnsafeMutablePointer<Bytef>(mutating:src.bindMemory(to:Bytef.self).baseAddress);stream.avail_in=uInt(compressed)
                    stream.next_out=dst.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(max(1,size));return inflate(&stream,Z_FINISH)
                }}
                guard status==Z_STREAM_END,stream.total_out==size else {throw MusicError.message("Пошкоджене стиснення ZIP.")};output=buffer.prefix(size)
            } else {throw MusicError.message("Непідтримуване стиснення ZIP.")}
            let checksum=output.withUnsafeBytes {crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(size))}
            guard checksum==uLong(crc) else {throw MusicError.message("Контрольна сума скіна не збігається.")}
            result[key]=output
        }
        return result
    }
}
