// Decodes every frame of a screen recording and reports, per frame, where the
// hero is: the bounding box of the hero's pixels inside the analysis region,
// how much of the region they cover, and how much of that is the magenta
// placeholder painted under the hero image.
//
//   swift analyze-frames.swift <video> <windowWidthPt> <x> <y> <w> <h> \
//     [<markerX> <markerY> <markerW> <markerH>]
//
// A hero pixel is one clearly brighter than the bench's dark background
// (#07111F). A push or a sheet also moves dimming layers, shadows and the
// incoming screen's faint edge highlight through the region; all of them stay
// below the threshold, so they are not mistaken for the hero.
//
// The optional marker rect is the bench's tap marker; each frame also reports
// the fraction of it that is lit (near white). The region is in window points
// (the bench screens use one fixed layout); the video's pixel scale is derived
// from its width. Output is one JSON object per frame on stdout. Uses
// AVFoundation only, so it needs no ffmpeg.
//
// Environment (both optional, for the gallery bench):
//   HERO_MASK       "x,y,w,h;x,y,w,h;..." window rects whose pixels are
//                   ignored: the gallery's other tiles, so only the measured
//                   photo is tracked (it stays visible in the gutters).
//   HERO_THRESHOLD  the hero-pixel threshold (default 110, any channel).
import AVFoundation
import CoreVideo
import Foundation

let args = CommandLine.arguments
guard args.count == 7 || args.count == 11,
  let windowWidth = Double(args[2]),
  let regionX = Double(args[3]), let regionY = Double(args[4]),
  let regionW = Double(args[5]), let regionH = Double(args[6])
else {
  FileHandle.standardError.write(
    "usage: analyze-frames.swift <video> <windowWidthPt> <x> <y> <w> <h> [<mx> <my> <mw> <mh>]\n"
      .data(using: .utf8)!)
  exit(2)
}

let marker: [Double]? =
  args.count == 11 ? args[7...10].compactMap { Double($0) } : nil

// The bench background is #07111F; the photo's edges are far brighter.
let heroThreshold =
  Int(ProcessInfo.processInfo.environment["HERO_THRESHOLD"] ?? "") ?? 110
let masks: [[Double]] = (ProcessInfo.processInfo.environment["HERO_MASK"] ?? "")
  .split(separator: ";")
  .map { $0.split(separator: ",").compactMap { Double($0) } }
  .filter { $0.count == 4 }
func isMasked(_ x: Double, _ y: Double) -> Bool {
  for rect in masks
  where x >= rect[0] && x < rect[0] + rect[2] && y >= rect[1]
    && y < rect[1] + rect[3]
  {
    return true
  }
  return false
}
// A pixel of the placeholder must be close to pure magenta.
func isPlaceholder(_ r: Int, _ g: Int, _ b: Int) -> Bool {
  return r > 200 && b > 200 && g < 70
}

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let semaphore = DispatchSemaphore(value: 0)
var videoTrack: AVAssetTrack?
Task {
  videoTrack = try? await asset.loadTracks(withMediaType: .video).first
  semaphore.signal()
}
semaphore.wait()
guard let track = videoTrack else {
  FileHandle.standardError.write("no video track\n".data(using: .utf8)!)
  exit(1)
}

let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(
  track: track,
  outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ])
output.alwaysCopiesSampleData = false
reader.add(output)
reader.startReading()

// Sample on a one-point grid: enough to place an edge to the nearest point.
var frameIndex = 0
while let sample = output.copyNextSampleBuffer() {
  guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
  let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
  let width = CVPixelBufferGetWidth(buffer)
  let height = CVPixelBufferGetHeight(buffer)
  let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
  let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(
    to: UInt8.self)
  let scale = Double(width) / windowWidth

  var minX = Double.infinity
  var minY = Double.infinity
  var maxX = -Double.infinity
  var maxY = -Double.infinity
  var samples = 0
  var visible = 0
  var placeholder = 0
  var pointY = regionY
  while pointY < regionY + regionH {
    let py = Int(pointY * scale)
    if py >= height { break }
    var pointX = regionX
    while pointX < regionX + regionW {
      let px = Int(pointX * scale)
      if px >= width { break }
      if !masks.isEmpty && isMasked(pointX, pointY) {
        pointX += 1
        continue
      }
      let pixel = base + py * rowBytes + px * 4
      let b = Int(pixel[0])
      let g = Int(pixel[1])
      let r = Int(pixel[2])
      samples += 1
      if r > heroThreshold || g > heroThreshold || b > heroThreshold {
        visible += 1
        if isPlaceholder(r, g, b) { placeholder += 1 }
        minX = min(minX, pointX)
        minY = min(minY, pointY)
        maxX = max(maxX, pointX + 1)
        maxY = max(maxY, pointY + 1)
      }
      pointX += 1
    }
    pointY += 1
  }

  var markerLit = 0.0
  if let rect = marker, rect.count == 4 {
    var lit = 0
    var total = 0
    var my = rect[1]
    while my < rect[1] + rect[3] {
      var mx = rect[0]
      while mx < rect[0] + rect[2] {
        let px = Int(mx * scale)
        let py = Int(my * scale)
        if px < width && py < height {
          let pixel = base + py * rowBytes + px * 4
          total += 1
          if pixel[0] > 200 && pixel[1] > 200 && pixel[2] > 200 { lit += 1 }
        }
        mx += 1
      }
      my += 1
    }
    markerLit = total == 0 ? 0 : Double(lit) / Double(total)
  }

  var record: [String: Any] = [
    "marker": markerLit,
    "frame": frameIndex,
    "t": (time * 100).rounded() / 100,
    "coverage": samples == 0 ? 0 : Double(visible) / Double(samples),
    "placeholder": visible == 0 ? 0 : Double(placeholder) / Double(visible),
  ]
  if visible > 0 {
    record["box"] = [minX, minY, maxX - minX, maxY - minY]
  }
  let data = try JSONSerialization.data(
    withJSONObject: record, options: [.sortedKeys])
  print(String(data: data, encoding: .utf8)!)
  frameIndex += 1
}

if reader.status == .failed {
  FileHandle.standardError.write(
    "decode failed: \(String(describing: reader.error))\n".data(using: .utf8)!)
  exit(1)
}
