import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Test hook: when set, `record` and `capture` skip ScreenCaptureKit, feed this many
/// synthetic frames, then fail the way a real stream does when the captured app's
/// connection drops (SCStreamError.failedApplicationConnectionInterrupted, -3805).
private let simulatedInterruptEnv = "CAPTURE_HELPER_TEST_INTERRUPT_AFTER_FRAMES"

let simulatedFrameWidth = 320
let simulatedFrameHeight = 240

func simulatedInterruptFrameCount() -> Int? {
    guard let raw = ProcessInfo.processInfo.environment[simulatedInterruptEnv],
          let frames = Int(raw), frames >= 0 else { return nil }
    return frames
}

/// Returns the frame timer; cancel it on the same queue to stop delivery early.
@discardableResult
func runSimulatedInterruptedStream(
    frames: Int,
    fps: Int32,
    queue: DispatchQueue,
    onFrame: @escaping (CVPixelBuffer, CMTime) -> Void,
    onStop: @escaping (Error) -> Void
) -> DispatchSourceTimer {
    var sent = 0
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
    timer.setEventHandler {
        guard sent < frames, let frame = syntheticFrame(shade: UInt8(truncatingIfNeeded: sent * 16)) else {
            timer.cancel()
            onStop(NSError(
                domain: SCStreamErrorDomain,
                code: SCStreamError.Code.failedApplicationConnectionInterrupted.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Failed during stream due to application connection being interrupted"]
            ))
            return
        }
        sent += 1
        onFrame(frame, CMClockGetTime(CMClockGetHostTimeClock()))
    }
    timer.resume()
    return timer
}

private func syntheticFrame(shade: UInt8) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
    guard CVPixelBufferCreate(kCFAllocatorDefault, simulatedFrameWidth, simulatedFrameHeight,
                              kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let base = CVPixelBufferGetBaseAddress(buffer) {
        memset(base, Int32(shade), CVPixelBufferGetDataSize(buffer))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}
