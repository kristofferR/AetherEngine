import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension HLSVideoEngine {

    /// The APAC rendition for the session's audio, when it is TrueHD or DTS-HD MA, the library accepts
    /// it as Atmos or DTS:X, and the session can serve one; nil keeps the stream-copy / bridge cascade.
    /// The rendition is checked before it is returned: about a second of the track is decoded where
    /// playback starts, so a track the library rejects (plain TrueHD, DTS-HD MA without DTS:X,
    /// unsupported object metadata) falls back to the bridge here instead of failing in front of AVPlayer.
    func makeSpatialAudio(streamIndex: Int32, stream: UnsafeMutablePointer<AVStream>, demuxer dem: Demuxer,
                          plan: [Segment], startIndex: Int, videoTimeBaseSeconds: Double,
                          masterRoutable: Bool) -> SpatialAudioSegmentSource? {
        let codecpar = stream.pointee.codecpar.pointee
        guard let kind = SpatialAudioTrackKind(codecID: codecpar.codec_id, profile: codecpar.profile,
                                               sampleRate: codecpar.sample_rate),
              let last = plan.last else { return nil }
        let originIsSerial = sourceReopenableByURL
            && (OriginRequestBudget.shared.requiresSerialRequests(sourceURL) || OriginRequestBudget.shared.isPaced(sourceURL))
        if let reason = SpatialAudioEligibility.absentReason(.init(
            allowed: spatialAudioAllowed,
            track: kind,
            refusedEarlier: spatialAudioRefusedStreamIndices.contains(streamIndex),
            isLive: isLiveSession,
            sequentialOrigin: sequentialOrigin,
            heldSourceConnection: openProfile.avioHeldConnection,
            originIsSerial: originIsSerial,
            isDiscSource: dem.isDiscSource,
            demuxedAudio: sideAudioDemuxer != nil,
            secondReaderAvailable: sourceReopenableByURL || makeSpatialAudioCustomReader != nil,
            masterRoutable: masterRoutable)) {
            EngineLog.emit("[SpatialAudio] \(kind.label) stays on the bridge: \(reason.rawValue)",
                           category: .audioBridge)
            return nil
        }
        #if canImport(SpatialAudioBridge)
        guard #available(tvOS 26, iOS 26, macOS 26, *) else {
            EngineLog.emit("[SpatialAudio] \(kind.label) stays on the bridge: APAC needs OS 26",
                           category: .audioBridge)
            return nil
        }
        let custom = sourceReopenableByURL ? nil : makeSpatialAudioCustomReader?()
        guard sourceReopenableByURL || custom != nil else {
            EngineLog.emit("[SpatialAudio] \(kind.label) stays on the bridge: the custom reader cannot clone",
                           category: .audioBridge)
            return nil
        }
        let url = sourceURL, headers = sourceHTTPHeaders
        let reader = SpatialAudioPacketReader(
            streamIndex: streamIndex, codecID: codecpar.codec_id, anchorStreamIndex: videoStreamIndex,
            open: { dem in
                if let custom {
                    try dem.open(reader: custom.reader, formatHint: custom.formatHint, profile: .spatialAudioSideDemuxer)
                } else {
                    try dem.open(url: url, extraHeaders: headers, profile: .spatialAudioSideDemuxer, isLive: false)
                }
            },
            cleanup: { custom?.reader.close() })
        let start = plan[min(max(startIndex, 0), plan.count - 1)]
        let started = DispatchTime.now()
        do {
            let rendition = SpatialAudioRendition(
                kind: kind, durationSeconds: last.startSeconds + last.durationSeconds, reader: reader)
            try Self.validateSpatialAudio(rendition, reader: reader,
                                          fromSourceSeconds: Double(start.startPts) * videoTimeBaseSeconds)
            rendition.onFailure = { [weak self] reason in
                self?.onSpatialAudioFailed?(streamIndex, reason)
            }
            rendition.prepare(atSeconds: start.startSeconds)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            EngineLog.emit(
                "[SpatialAudio] \(kind.spatialLabel) stream \(streamIndex) served as APAC \(rendition.codecs) "
                + "(\(rendition.channelCount) channels, \(rendition.segmentCount) segments, checked in "
                + "\(String(format: "%.0f", ms)) ms)", category: .audioBridge)
            return rendition
        } catch {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            EngineLog.emit(
                "[SpatialAudio] \(kind.label) stream \(streamIndex) falls back to the bridge after "
                + "\(String(format: "%.0f", ms)) ms: \(error)", category: .audioBridge)
            return nil
        }
        #else
        return nil
        #endif
    }

    #if canImport(SpatialAudioBridge)
    /// `start()` is synchronous and already runs off the cooperative pool (`BlockingWork`), so the check
    /// is awaited on a semaphore. A source that does not answer within the bound falls back.
    @available(tvOS 26, iOS 26, macOS 26, *)
    private static func validateSpatialAudio(_ rendition: SpatialAudioRendition, reader: SpatialAudioPacketReader,
                                             fromSourceSeconds seconds: Double) throws {
        final class Outcome: @unchecked Sendable { var error: (any Error)? }
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let task = BlockingWork.detached(priority: .userInitiated) {
            do { try await rendition.validate(fromSourceSeconds: seconds) } catch { outcome.error = error }
            done.signal()
        }
        guard done.wait(timeout: .now() + 15) == .success else {
            task.cancel()
            reader.interrupt()
            BlockingWork.detached(priority: .utility) {
                await task.value
                reader.close()
            }
            throw SpatialAudioPacketReader.ReadError(description: "the check did not finish within 15 s")
        }
        if let error = outcome.error {
            reader.close()
            throw error
        }
    }
    #endif
}
