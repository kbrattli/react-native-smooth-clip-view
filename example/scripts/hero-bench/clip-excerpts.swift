// Cuts constant-frame-rate excerpts out of a bench recording, for videos.
//
//   swift clip-excerpts.swift <recording.mp4> <out-dir> <fps> <name>:<startS>:<endS> ...
//
// The bench's recordings have a variable frame rate: the recorder writes a
// frame only when the screen changes, so their average rate is low (about 10
// to 25 fps over a whole recording, 60 during a run). A Remotion render of
// such a recording at 0.5x skipped up to a third of a run's frames and held
// others for 100 ms (docs/gallery-mount-time.md, "Why the Android clips
// looked laggy"). Each excerpt here has a frame every 1/fps s from its start:
// the recording's frame on screen at that time (the last one at or before
// it), so a render that samples it on the same grid shows every frame the
// recording has, at its time. Use fps = output fps / speed (120 for a 60 fps
// video at 0.5x). The excerpt keeps the recording's size. AVFoundation only.
import AVFoundation
import Foundation

let args = CommandLine.arguments
guard args.count >= 5, let fps = Double(args[3]) else {
  FileHandle.standardError.write(
    "usage: clip-excerpts.swift <recording.mp4> <out-dir> <fps> <name>:<startS>:<endS> ...\n"
      .data(using: .utf8)!)
  exit(2)
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let semaphore = DispatchSemaphore(value: 0)
var videoTrack: AVAssetTrack?
var naturalSize = CGSize.zero
Task {
  videoTrack = try? await asset.loadTracks(withMediaType: .video).first
  if let track = videoTrack { naturalSize = try await track.load(.naturalSize) }
  semaphore.signal()
}
semaphore.wait()
guard let track = videoTrack else {
  FileHandle.standardError.write("no video track\n".data(using: .utf8)!)
  exit(1)
}

/// The recording's frames from `from` to `to` (seconds), decoded.
func readFrames(from: Double, to: Double) throws -> [(Double, CVPixelBuffer)] {
  let reader = try AVAssetReader(asset: asset)
  reader.timeRange = CMTimeRange(
    start: CMTime(seconds: max(0, from), preferredTimescale: 90000),
    end: CMTime(seconds: to, preferredTimescale: 90000))
  let output = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String:
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
  reader.add(output)
  reader.startReading()
  var frames: [(Double, CVPixelBuffer)] = []
  while let sample = output.copyNextSampleBuffer() {
    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
    frames.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, buffer))
  }
  if reader.status == .failed { throw reader.error! }
  return frames
}

for spec in args[4...] {
  let parts = spec.split(separator: ":")
  guard parts.count == 3, let start = Double(parts[1]), let end = Double(parts[2])
  else {
    FileHandle.standardError.write("bad excerpt \(spec)\n".data(using: .utf8)!)
    exit(2)
  }
  let name = String(parts[0])
  // The screen can stand still for seconds: start reading early enough to
  // have the frame on screen at `start`.
  let frames = try readFrames(from: start - 4, to: end + 0.1)
  guard !frames.isEmpty else {
    FileHandle.standardError.write("\(name): no frames\n".data(using: .utf8)!)
    exit(1)
  }
  let url = outDir.appendingPathComponent("\(name).mp4")
  try? FileManager.default.removeItem(at: url)
  let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
  let pixels = naturalSize.width * naturalSize.height
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: naturalSize.width,
      AVVideoHeightKey: naturalSize.height,
      AVVideoCompressionPropertiesKey: [
        // About 0.25 bit per pixel per frame: far above the recordings'.
        AVVideoAverageBitRateKey: Int(pixels * fps * 0.25),
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ])
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input, sourcePixelBufferAttributes: nil)
  writer.add(input)
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)
  let ticks = Int(((end - start) * fps).rounded(.up)) + 1
  var at = 0
  var shown = Set<Int>()
  for tick in 0..<ticks {
    let time = start + Double(tick) / fps + 1e-6
    while at + 1 < frames.count && frames[at + 1].0 <= time { at += 1 }
    shown.insert(at)
    while !input.isReadyForMoreMediaData { usleep(1000) }
    adaptor.append(
      frames[at].1,
      withPresentationTime: CMTime(value: CMTimeValue(tick), timescale: CMTimeScale(fps)))
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  if writer.status != .completed {
    FileHandle.standardError.write(
      "\(name): \(String(describing: writer.error))\n".data(using: .utf8)!)
    exit(1)
  }
  let inWindow = frames.filter { $0.0 > start && $0.0 <= end }.count
  print(
    "\(name): \(ticks) frames at \(Int(fps)) fps from \(start) s, \(shown.count) recording frames shown (\(inWindow) recorded inside the window)"
  )
}
