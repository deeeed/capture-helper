import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

/// ScreenCaptureKit presentation times use the CoreMedia host clock. Bracket
/// the wall-clock conversion rather than treating process launch as frame zero.
struct RecordingClockSample {
    let earliestOffsetMs: Double
    let latestOffsetMs: Double

    static func measure() -> RecordingClockSample {
        let before = Date().timeIntervalSince1970 * 1000
        let host = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1000
        let after = Date().timeIntervalSince1970 * 1000
        return RecordingClockSample(earliestOffsetMs: before - host, latestOffsetMs: after - host)
    }
}

/// Read final encoded sample times natively; do not advertise accepted writer
/// samples as frames in the MP4 until AVFoundation has finalized the file.
func finalizedRecordingTiming(output: URL) async throws -> (frames: [Double], duration: Double, digest: String) {
    let asset = AVURLAsset(url: output)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw CaptureError.recordFailed("recorded file has no video track")
    }
    let reader = try AVAssetReader(asset: asset)
    let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(samples) else { throw CaptureError.recordFailed("cannot inspect recorded video samples") }
    reader.add(samples)
    guard reader.startReading() else { throw CaptureError.recordFailed("cannot read recorded video timing") }
    var frames: [Double] = []
    while let buffer = samples.copyNextSampleBuffer() {
        for index in 0..<CMSampleBufferGetNumSamples(buffer) {
            var timing = CMSampleTimingInfo()
            guard CMSampleBufferGetSampleTimingInfo(buffer, at: index, timingInfoOut: &timing) == noErr else {
                throw CaptureError.recordFailed("cannot read recorded sample timing")
            }
            frames.append(CMTimeGetSeconds(timing.presentationTimeStamp) * 1000)
        }
    }
    guard reader.status == .completed else {
        throw CaptureError.recordFailed("reading recorded video timing failed: \(reader.error?.localizedDescription ?? "unknown error")")
    }
    let duration = CMTimeGetSeconds(try await asset.load(.duration)) * 1000
    frames.sort()
    guard !frames.isEmpty, duration.isFinite, duration > frames.last!,
          frames.enumerated().allSatisfy({ index, value in value.isFinite && value >= 0 && (index == 0 || value > frames[index - 1]) }) else {
        throw CaptureError.recordFailed("recorded video has invalid frame timestamps")
    }
    let file = try FileHandle(forReadingFrom: output)
    defer { try? file.close() }
    var hash = SHA256()
    while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty { hash.update(data: bytes) }
    return (frames, duration, "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined())
}
