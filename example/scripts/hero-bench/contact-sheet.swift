// Tiles every frame a screen recording shows between two times into one PNG,
// each labelled with its time in ms after `t0`, so a transition can be checked
// frame by frame (a blank frame, a double image, a jump). AVFoundation only.
//
//   swift contact-sheet.swift <video> <startMs> <endMs> <out.png> \
//     [t0Ms=startMs] [columns=10] [tileWidth=150]
import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 5, let startMs = Double(args[2]), let endMs = Double(args[3])
else {
  FileHandle.standardError.write(
    "usage: contact-sheet.swift <video> <startMs> <endMs> <out.png> [t0Ms] [columns] [tileWidth]\n"
      .data(using: .utf8)!)
  exit(2)
}
let t0Ms = args.count > 5 ? Double(args[5]) ?? startMs : startMs
let columns = args.count > 6 ? Int(args[6]) ?? 10 : 10
let tileWidth = args.count > 7 ? Int(args[7]) ?? 150 : 150

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let semaphore = DispatchSemaphore(value: 0)
var videoTrack: AVAssetTrack?
Task {
  videoTrack = try? await asset.loadTracks(withMediaType: .video).first
  semaphore.signal()
}
semaphore.wait()
guard let track = videoTrack else { exit(1) }
let reader = try AVAssetReader(asset: asset)
reader.timeRange = CMTimeRange(
  start: CMTime(seconds: max(0, startMs - 100) / 1000, preferredTimescale: 600),
  end: CMTime(seconds: endMs / 1000 + 0.1, preferredTimescale: 600))
let output = AVAssetReaderTrackOutput(
  track: track,
  outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
  ])
reader.add(output)
reader.startReading()

var tiles: [(ms: Double, image: CGImage)] = []
while let sample = output.copyNextSampleBuffer() {
  let ms = CMSampleBufferGetPresentationTimeStamp(sample).seconds * 1000
  if ms < startMs || ms > endMs { continue }
  guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
  CVPixelBufferLockBaseAddress(buffer, .readOnly)
  let width = CVPixelBufferGetWidth(buffer)
  let height = CVPixelBufferGetHeight(buffer)
  let context = CGContext(
    data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
    bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
      | CGBitmapInfo.byteOrder32Little.rawValue)
  if let image = context?.makeImage() { tiles.append((ms, image)) }
  CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
}
guard let first = tiles.first else {
  FileHandle.standardError.write("no frames in range\n".data(using: .utf8)!)
  exit(1)
}
let tileHeight = tileWidth * first.image.height / first.image.width
let labelHeight = 18
let rows = (tiles.count + columns - 1) / columns
let sheetWidth = columns * (tileWidth + 2)
let sheetHeight = rows * (tileHeight + labelHeight + 2)
let sheet = CGContext(
  data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
sheet.setFillColor(CGColor(red: 0.5, green: 0, blue: 0, alpha: 1))
sheet.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
let font = CTFontCreateWithName("Menlo-Bold" as CFString, 13, nil)
for (index, tile) in tiles.enumerated() {
  let column = index % columns
  let row = index / columns
  let x = column * (tileWidth + 2)
  // CoreGraphics' origin is bottom-left.
  let top = sheetHeight - row * (tileHeight + labelHeight + 2)
  sheet.draw(
    tile.image,
    in: CGRect(
      x: x, y: top - labelHeight - tileHeight, width: tileWidth,
      height: tileHeight))
  let text = String(format: "%.1f", tile.ms - t0Ms)
  let attributed = NSAttributedString(
    string: text,
    attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String):
        CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    ])
  let line = CTLineCreateWithAttributedString(attributed)
  sheet.textPosition = CGPoint(x: x + 4, y: top - labelHeight + 4)
  CTLineDraw(line, sheet)
}
let url = URL(fileURLWithPath: args[4])
let destination = CGImageDestinationCreateWithURL(
  url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, sheet.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("\(tiles.count) frames -> \(args[4])")
