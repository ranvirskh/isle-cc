import AVFoundation
import AppKit
// usage: fdiff <movie>   prints per-frame: index, time, bounding height of non-background (black island) pixels, diff vs previous
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let track = asset.tracks(withMediaType: .video).first!
let reader = try! AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
reader.add(out); reader.startReading()
var prev: [UInt8]? = nil
var i = 0
while let sb = out.copyNextSampleBuffer() {
    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    // island silhouette: rows with a meaningful share of near-black pixels
    var lowest = 0; var widthAtMid = 0
    var rowBlack = [Int](repeating: 0, count: h)
    for y in 0..<h { var c = 0; var x = 0; while x < w { let p = base + y * bpr + x * 4; if Int(p[0]) + Int(p[1]) + Int(p[2]) < 24 { c += 1 }; x += 2 }; rowBlack[y] = c }
    for y in 0..<h where rowBlack[y] > w / 2 / 10 { lowest = y }
    var minX = w, maxX = 0
    let ym = max(0, lowest - 24)
    for x in 0..<w { let p = base + ym * bpr + x * 4; if Int(p[0]) + Int(p[1]) + Int(p[2]) < 24 { minX = min(minX, x); maxX = max(maxX, x) } }
    widthAtMid = maxX > minX ? maxX - minX : 0
    // sampled signature for diff
    var sig = [UInt8](); var y = 0
    while y < h { var x = 0; while x < w { sig.append(base[y * bpr + x * 4 + 1]); x += 8 }; y += 8 }
    var d = 0
    if let p = prev { for k in 0..<sig.count { d += abs(Int(sig[k]) - Int(p[k])) } }
    prev = sig
    print(String(format: "%3d t=%.3f h=%3d w=%4d diff=%d", i, t, lowest / 2, widthAtMid / 2, d))
    CVPixelBufferUnlockBaseAddress(pb, .readOnly); i += 1
}
