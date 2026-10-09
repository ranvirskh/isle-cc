import AVFoundation
import AppKit
// usage: frames <movie> <outdir> [step]
let a = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]))
let out = a[2]; try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let track = asset.tracks(withMediaType: .video).first!
let fps = Double(track.nominalFrameRate)
let dur = CMTimeGetSeconds(asset.duration)
print("fps \(fps) dur \(dur) size \(track.naturalSize)")
let gen = AVAssetImageGenerator(asset: asset)
gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
gen.appliesPreferredTrackTransform = true
let step = a.count > 3 ? Int(a[3])! : 1
var i = 0; var n = 0
while Double(i) / fps < dur {
    let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
    if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/f%04d.png", out, i)))
        n += 1
    }
    i += step
}
print("wrote \(n)")
