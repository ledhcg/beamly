import CoreMedia
import Foundation
import VideoToolbox

/// Low-latency hardware H.264 encoder. Emits CONFIG before every key frame, then the frame in Annex-B format.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let sender: Sender
    private let width: Int
    private let height: Int
    private var forceKeyFrame = true

    init(width: Int, height: Int, fps: Int, bitrate: Int, sender: Sender) throws {
        self.width = width
        self.height = height
        self.sender = sender

        // Prefer the low-latency rate controller; fall back to the default encoder if unavailable.
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var status = Self.createSession(width: width, height: height, specification: lowLatency, into: &session)
        if status != noErr {
            status = Self.createSession(width: width, height: height, specification: nil, into: &session)
        }
        guard status == noErr, let session else { throw BeamlyError("Cannot create the H.264 encoder (\(status))") }

        func set(_ key: CFString, _ value: CFTypeRef) { _ = VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 2) as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    private static func createSession(
        width: Int, height: Int, specification: CFDictionary?, into session: inout VTCompressionSession?
    ) -> OSStatus {
        VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: specification, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    }

    func invalidate() {
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
    }

    func encode(_ image: CVImageBuffer, presentationTime: CMTime) {
        guard let session else { return }
        var properties: CFDictionary?
        if forceKeyFrame {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            forceKeyFrame = false
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: presentationTime, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.output(sampleBuffer)
        }
    }

    private func output(_ sampleBuffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let attachments =
            CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        let pts = UInt64(max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1_000_000))

        if isKeyFrame, let format = CMSampleBufferGetFormatDescription(sampleBuffer) { sendConfig(format) }

        let length = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: length)
        let copied = avcc.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return }
        sender.send(isKeyFrame ? .keyFrame : .frame, ptsMicros: pts, payload: PacketCodec.annexB(fromAVCC: avcc))
    }

    private func sendConfig(_ format: CMFormatDescription) {
        var parameterSets: [Data] = []
        for index in 0..<2 {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return }
            parameterSets.append(Data(bytes: pointer, count: size))
        }
        let payload = PacketCodec.configPayload(
            width: width, height: height, sps: parameterSets[0], pps: parameterSets[1])
        sender.send(.config, payload: payload)
    }
}
