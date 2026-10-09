import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import VideoToolbox

class WindowSlot {
    let index: UInt8
    let name: String
    let session: VTCompressionSession
    let stream: SCStream?
    let delegate: CaptureDelegate
    let errorDelegate: WindowErrorDelegate
    let outWidth: Int
    let outHeight: Int

    init(index: UInt8, name: String, session: VTCompressionSession, stream: SCStream?,
         delegate: CaptureDelegate, errorDelegate: WindowErrorDelegate,
         outWidth: Int, outHeight: Int) {
        self.index = index
        self.name = name
        self.session = session
        self.stream = stream
        self.delegate = delegate
        self.errorDelegate = errorDelegate
        self.outWidth = outWidth
        self.outHeight = outHeight
    }

    func stop() {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        stream?.stopCapture { _ in }
    }
}

var slots: [WindowSlot?] = []

func allocateIndex() -> UInt8 {
    if let freeIndex = slots.firstIndex(where: { $0 == nil }) {
        return UInt8(freeIndex)
    }
    let index = slots.count
    slots.append(nil)
    return UInt8(index)
}

var activeWindowCount: Int {
    slots.compactMap { $0 }.count
}

func addWindowCapture(name: String, window: SCWindow) async throws -> WindowSlot {
    let index = allocateIndex()
    let cfg = Runtime.config

    let srcW = Int(window.frame.width)
    let srcH = Int(window.frame.height)
    let scale = min(Double(cfg.maxSize) / Double(max(srcW, srcH)), 1.0)
    let outW = max(2, Int(Double(srcW) * scale) & ~1)
    let outH = max(2, Int(Double(srcH) * scale) & ~1)
    let session = try makeCompressionSession(width: outW, height: outH, maxFps: cfg.maxFps)

    let filter = SCContentFilter(desktopIndependentWindow: window)
    let streamConfig = SCStreamConfiguration()
    streamConfig.minimumFrameInterval = .zero
    streamConfig.width = outW
    streamConfig.height = outH
    streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
    streamConfig.showsCursor = false
    streamConfig.queueDepth = 3

    let errorDelegate = WindowErrorDelegate(windowIndex: index)
    let stream = SCStream(filter: filter, configuration: streamConfig, delegate: errorDelegate)

    let delegate = CaptureDelegate(session: session, maxFps: cfg.maxFps, windowIndex: index)
    try stream.addStreamOutput(delegate, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture-\(index)"))

    try await stream.startCapture()

    let slot = WindowSlot(
        index: index, name: name, session: session, stream: stream,
        delegate: delegate, errorDelegate: errorDelegate,
        outWidth: outW, outHeight: outH
    )
    slots[Int(index)] = slot
    return slot
}

/// Test hook counterpart of addWindowCapture: synthetic frames, then a simulated stream interruption.
func addSimulatedWindowCapture(frames: Int) throws -> WindowSlot {
    let index = allocateIndex()
    let cfg = Runtime.config
    let session = try makeCompressionSession(width: simulatedFrameWidth, height: simulatedFrameHeight, maxFps: cfg.maxFps)
    let errorDelegate = WindowErrorDelegate(windowIndex: index)
    let delegate = CaptureDelegate(session: session, maxFps: cfg.maxFps, windowIndex: index)
    let slot = WindowSlot(
        index: index, name: "simulated", session: session, stream: nil,
        delegate: delegate, errorDelegate: errorDelegate,
        outWidth: simulatedFrameWidth, outHeight: simulatedFrameHeight
    )
    slots[Int(index)] = slot
    runSimulatedInterruptedStream(frames: frames, fps: cfg.maxFps, queue: DispatchQueue(label: "capture-\(index)"),
                                  onFrame: delegate.encode, onStop: errorDelegate.streamDidStop)
    return slot
}

private func makeCompressionSession(width outW: Int, height outH: Int, maxFps: Int32) throws -> VTCompressionSession {
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(
        allocator: nil,
        width: Int32(outW), height: Int32(outH),
        codecType: kCMVideoCodecType_H264,
        encoderSpecification: nil,
        imageBufferAttributes: nil,
        compressedDataAllocator: nil,
        outputCallback: nil,
        refcon: nil,
        compressionSessionOut: &session
    )
    guard status == noErr, let session else {
        throw CaptureError.setupFailed("VTCompressionSessionCreate failed: \(status)")
    }

    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 500_000 as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (maxFps * 2) as CFNumber)
    VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
    VTCompressionSessionPrepareToEncodeFrames(session)
    return session
}

func removeWindowCapture(index: Int) {
    guard index < slots.count, let slot = slots[index] else { return }
    slot.stop()
    slots[index] = nil
}

func removeAllWindows() {
    for index in 0..<slots.count {
        if let slot = slots[index] {
            slot.stop()
            slots[index] = nil
        }
    }
}

class WindowErrorDelegate: NSObject, SCStreamDelegate {
    let windowIndex: UInt8

    init(windowIndex: UInt8) {
        self.windowIndex = windowIndex
        super.init()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        streamDidStop(with: error)
    }

    func streamDidStop(with error: Error) {
        let index = Int(windowIndex)
        logErrorMessage(code: "stream_stopped", message: "window[\(windowIndex)] stream stopped: \(error)", context: ["windowIndex": index])
        let stats = index < slots.count ? slots[index]?.delegate.encodedStats() : nil
        // Flush frames already handed to the encoder before reporting what was kept.
        removeWindowCapture(index: index)
        logStreamInterrupted(frames: stats?.frames ?? 0, mediaTimeMs: stats?.mediaTimeMs ?? 0, cause: error,
                             context: ["index": index])
        logEvent(("type", "removed"), ("index", index))
        // A framed session keeps running so its controller can add windows; a plain capture has nothing left to stream.
        if !Runtime.config.framed && activeWindowCount == 0 {
            exit(streamInterruptedExitCode)
        }
    }
}

class CaptureDelegate: NSObject, SCStreamOutput {
    let session: VTCompressionSession
    let maxFps: Int32
    let windowIndex: UInt8
    private var frameCount: Int64 = 0
    private let keyFrameInterval: Int64
    private let minEncodeInterval: CMTime
    private var lastEncodedPts: CMTime = .invalid
    private var firstEncodedPts: CMTime = .invalid
    private let statsLock = NSLock()

    init(session: VTCompressionSession, maxFps: Int32, windowIndex: UInt8) {
        self.session = session
        self.maxFps = maxFps
        self.windowIndex = windowIndex
        self.keyFrameInterval = Int64(maxFps) * 2
        self.minEncodeInterval = CMTime(value: 1, timescale: maxFps)
        super.init()
    }

    func encodedStats() -> (frames: Int, mediaTimeMs: Double) {
        statsLock.withLock {
            let media = lastEncodedPts.isValid ? CMTimeGetSeconds(CMTimeSubtract(lastEncodedPts, firstEncodedPts)) * 1000 : 0
            return (Int(frameCount), media)
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if lastEncodedPts.isValid {
            let delta = CMTimeSubtract(pts, lastEncodedPts)
            if delta.isNumeric && CMTimeCompare(delta, minEncodeInterval) < 0 {
                return
            }
        }
        let duration = CMTime(value: 1, timescale: maxFps)

        var properties: CFDictionary? = nil
        if frameCount % keyFrameInterval == 0 {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }

        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
                                        presentationTimeStamp: pts, duration: duration,
                                        frameProperties: properties,
                                        infoFlagsOut: nil, outputHandler: { [self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self.handleEncodedFrame(sampleBuffer)
        })
        statsLock.withLock {
            if !firstEncodedPts.isValid { firstEncodedPts = pts }
            lastEncodedPts = pts
            frameCount += 1
        }
        if frameCount == 1 || frameCount % 300 == 0 {
            log("info", "window=\(windowIndex) frames=\(frameCount)")
        }
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return }

        let isKeyframe = !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var output = Data()

        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            output.append(extractParameterSets(from: format))
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength, dataPointerOut: &dataPointer) == noErr,
              let pointer = dataPointer else { return }

        let frameData = Data(bytes: pointer, count: totalLength)
        output.append(lengthPrefixedToAnnexB(frameData))

        if Runtime.config.framed {
            var header = Data(count: 6)
            let length = UInt32(output.count)
            header[0] = UInt8((length >> 24) & 0xFF)
            header[1] = UInt8((length >> 16) & 0xFF)
            header[2] = UInt8((length >> 8) & 0xFF)
            header[3] = UInt8(length & 0xFF)
            header[4] = isKeyframe ? 1 : 0
            header[5] = windowIndex
            writeStdout(header + output)
        } else {
            writeStdout(output)
        }
    }
}
