import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
#if canImport(SpatialAudioBridge)
import CoreMedia
import SpatialAudioBridge
#endif

/// A spatial audio rendition as the session and the segment provider see it: an APAC media playlist
/// and its segments, served beside the video variant as its `EXT-X-MEDIA:TYPE=AUDIO` rendition.
/// Free of the OS availability the library imposes, so neither needs to carry it.
protocol SpatialAudioSegmentSource: AnyObject, Sendable {
    /// `apac.31.03` for 7.1.4, for the variant's CODECS.
    var codecs: String { get }
    var channelCount: Int { get }
    var bitRate: Int { get }
    var mediaPlaylist: String { get }
    /// What `audioPipelineDescription` reports, such as "TrueHD Atmos → APAC 7.1.4 (Spatial Audio)".
    var pipelineDescription: String { get }
    /// Both may block while conversion catches up; nil when it cannot deliver.
    func initSegment() -> Data?
    func segment(at index: Int) -> Data?
    /// The source-clock shift the video is muxed with, from the first producer that opens its gate.
    func setSourceOffset(_ seconds: Double)
    /// Starts converting the segment at output time `seconds` before AVPlayer asks for it.
    func prepare(atSeconds seconds: Double)
    func shutdown()
}

/// Whether a session serves its audio as an APAC rendition. Mirrors `IFrameRenditionEligibility`:
/// the rendition needs a second reader on the source and a master playlist to be listed in.
enum SpatialAudioEligibility {
    enum AbsentReason: String, Equatable {
        case notAllowed, notConvertible, refusedEarlier, live, sequentialOrigin, heldSourceConnection
        case serialOrigin, discSource, demuxedAudio, noSecondReader, mediaPlaylistRouting
    }

    struct Inputs {
        /// The host's option, and the routes APAC cannot take (AirPlay).
        var allowed: Bool
        var track: SpatialAudioTrackKind?
        /// The library already rejected this stream in this session, which is now rebuilt on the bridge.
        var refusedEarlier: Bool
        var isLive: Bool
        var sequentialOrigin: Bool
        var heldSourceConnection: Bool
        var originIsSerial: Bool
        var isDiscSource: Bool
        var demuxedAudio: Bool
        var secondReaderAvailable: Bool
        /// Whether the session can serve a master playlist, the only place a rendition can live.
        var masterRoutable: Bool
    }

    static func absentReason(_ i: Inputs) -> AbsentReason? {
        guard i.allowed else { return .notAllowed }
        guard i.track != nil else { return .notConvertible }
        if i.refusedEarlier { return .refusedEarlier }
        if i.isLive { return .live }
        if i.sequentialOrigin { return .sequentialOrigin }
        if i.heldSourceConnection { return .heldSourceConnection }
        if i.originIsSerial { return .serialOrigin }
        if i.isDiscSource { return .discSource }
        if i.demuxedAudio { return .demuxedAudio }
        guard i.secondReaderAvailable else { return .noSecondReader }
        guard i.masterRoutable else { return .mediaPlaylistRouting }
        return nil
    }
}

/// Which source tracks the spatial audio rendition offers to SpatialAudioBridge: every 48 kHz TrueHD
/// and DTS-HD Master Audio track. FFmpeg's profile is not the test, because it reports alternate
/// DTS:X presentations as plain DTS-HD MA; the library's is, as soon as decoding starts, and it rejects
/// plain TrueHD and DTS-HD MA without DTS:X there (its integration guide, "Let the library recognise
/// DTS:X"). Every other track keeps the bridge without being tried.
enum SpatialAudioTrackKind: Equatable {
    case trueHD
    case dtsHDMA

    init?(codecID: AVCodecID, profile: Int32, sampleRate: Int32) {
        guard sampleRate == 48_000 else { return nil }
        switch codecID {
        case AV_CODEC_ID_TRUEHD: self = .trueHD
        case AV_CODEC_ID_DTS where [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X,
                                    AV_PROFILE_DTS_HD_MA_X_IMAX].contains(profile): self = .dtsHDMA
        default: return nil
        }
    }

    /// The track as offered.
    var label: String {
        switch self {
        case .trueHD: "TrueHD"
        case .dtsHDMA: "DTS-HD MA"
        }
    }

    /// The track as the library accepted it.
    var spatialLabel: String {
        switch self {
        case .trueHD: "TrueHD Atmos"
        case .dtsHDMA: "DTS:X"
        }
    }

    /// Where the first access unit at or after `offset` that a conversion can start on begins: a
    /// TrueHD major sync (the decoder refuses to skip bytes to find one) or a DTS core sync. Nil
    /// when the packet holds none.
    func syncOffset(in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            switch self {
            case .dtsHDMA:
                // FFmpeg's DTS packets are whole frames, each opening on the core sync word.
                guard bytes.count >= 4, bytes[0] == 0x7F, bytes[1] == 0xFE, bytes[2] == 0x80, bytes[3] == 0x01
                else { return nil }
                return 0
            case .trueHD:
                // An access unit opens with a 12-bit length in 16-bit words; one that starts a
                // restart interval carries the major sync 0xF8726FBA right after its 4-byte header.
                var offset = 0
                while offset + 8 <= bytes.count {
                    if bytes[offset + 4] == 0xF8, bytes[offset + 5] == 0x72,
                       bytes[offset + 6] == 0x6F, bytes[offset + 7] == 0xBA {
                        return offset
                    }
                    let words = (Int(bytes[offset] & 0x0F) << 8) | Int(bytes[offset + 1])
                    guard words >= 2 else { return nil }
                    offset += words * 2
                }
                return nil
            }
        }
    }

    /// Duration of the access units before `offset` in a TrueHD packet, which a packet's own time
    /// does not cover once the conversion starts later inside it. 40 samples each at 48 kHz.
    func skippedSeconds(in data: Data, before offset: Int) -> Double {
        guard self == .trueHD, offset > 0 else { return 0 }
        var units = 0
        var position = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while position + 2 <= offset {
                let words = (Int(bytes[position] & 0x0F) << 8) | Int(bytes[position + 1])
                guard words >= 2 else { break }
                position += words * 2
                units += 1
            }
        }
        return Double(units) * 40 / 48_000
    }
}

/// Reads one audio track on a demuxer of its own, opened on first use. The pump keeps the session's
/// demuxer; the rendition seeks wherever AVPlayer asks for audio, independently of the video.
final class SpatialAudioPacketReader: @unchecked Sendable {
    struct Packet {
        let data: Data
        /// Presentation time on the source clock; nil for laced frames libavformat left unstamped.
        let seconds: Double?
    }

    private let open: (Demuxer) throws -> Void
    private let cleanup: () -> Void
    private let streamIndex: Int32
    private let codecID: AVCodecID
    /// The video stream, which carries the seek index of an indexed container: a Matroska seek
    /// anchored on the audio, which has no cues, would scan the file from the last indexed cluster.
    private let anchorStreamIndex: Int32
    private let lock = NSLock()
    private var demuxer: Demuxer?
    private var timeBase = AVRational(num: 0, den: 1)
    /// What a seek is measured against on the open demuxer: the video, or the audio itself on
    /// MPEG-TS, whose seek is a timestamp search that only sees the streams this reader keeps.
    private var seekStreamIndex: Int32 = -1
    private var interrupted = false
    private var cleanedUp = false

    struct ReadError: Error, CustomStringConvertible {
        let description: String
    }

    init(streamIndex: Int32, codecID: AVCodecID, anchorStreamIndex: Int32,
         open: @escaping (Demuxer) throws -> Void, cleanup: @escaping () -> Void = {}) {
        self.streamIndex = streamIndex
        self.codecID = codecID
        self.anchorStreamIndex = anchorStreamIndex
        self.open = open
        self.cleanup = cleanup
    }

    private func readyDemuxer() throws -> Demuxer {
        lock.lock()
        if interrupted { lock.unlock(); throw CancellationError() }
        if let demuxer { lock.unlock(); return demuxer }
        let dem = Demuxer()
        demuxer = dem
        lock.unlock()
        do {
            try open(dem)
            guard let stream = dem.stream(at: streamIndex),
                  stream.pointee.codecpar.pointee.codec_id == codecID else {
                throw ReadError(description: "stream \(streamIndex) is not the session's audio track")
            }
            let tb = stream.pointee.time_base
            guard tb.num > 0, tb.den > 0 else { throw ReadError(description: "stream \(streamIndex) has no time base") }
            dem.discardAllStreamsExcept([streamIndex])
            let seekStream = dem.containerFormatName == "mpegts" ? streamIndex : anchorStreamIndex
            lock.lock()
            timeBase = tb
            seekStreamIndex = seekStream
            let wasInterrupted = interrupted
            lock.unlock()
            if wasInterrupted { throw CancellationError() }
            return dem
        } catch {
            drop(dem)
            throw error
        }
    }

    private func drop(_ dem: Demuxer) {
        lock.lock()
        if demuxer === dem { demuxer = nil }
        lock.unlock()
        dem.markClosed()
        dem.close()
    }

    /// Positions the reader at the last seek point at or before `seconds` on the source clock.
    func seek(toSourceSeconds seconds: Double) throws {
        let dem = try readyDemuxer()
        // A target before the first timestamp is the start: an MPEG-TS seek fails below it rather
        // than landing there, and a seek lead near the start of any source reaches below it.
        let target = max(seconds, dem.resolvedSourceStartOrigin)
        lock.lock()
        let seekStream = seekStreamIndex
        lock.unlock()
        guard dem.seekBounded(to: target, anchorStreamIndex: seekStream, timeout: 8) else {
            // The session treats a demuxer whose seek failed as suspect; a reopen is cheap next to a stall.
            drop(dem)
            throw ReadError(description: "seek to \(String(format: "%.3f", target)) s failed")
        }
    }

    /// The track's next packet, nil at the end of the source.
    func next() throws -> Packet? {
        let dem = try readyDemuxer()
        while true {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try dem.readPacket()
            } catch {
                drop(dem)
                throw error
            }
            guard let packet else { return nil }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { av_packet_free(&owned) }
            guard packet.pointee.stream_index == streamIndex, let bytes = packet.pointee.data,
                  packet.pointee.size > 0 else { continue }
            lock.lock()
            let tb = timeBase
            lock.unlock()
            let pts = packet.pointee.pts
            return Packet(data: Data(bytes: bytes, count: Int(packet.pointee.size)),
                          seconds: pts == Int64.min ? nil : Double(pts) * Double(tb.num) / Double(tb.den))
        }
    }

    /// Any thread. Aborts an open or a read in flight; every later call throws.
    func interrupt() {
        lock.lock()
        interrupted = true
        let dem = demuxer
        lock.unlock()
        dem?.markClosed()
    }

    /// After the last read, from the thread that made it.
    func close() {
        lock.lock()
        let dem = demuxer
        demuxer = nil
        let runCleanup = !cleanedUp
        cleanedUp = true
        lock.unlock()
        dem?.close()
        if runCleanup { cleanup() }
    }
}

#if canImport(SpatialAudioBridge)
/// Serves a TrueHD Atmos or DTS:X track to AVPlayer as an APAC audio rendition, converted on demand
/// by SpatialAudioBridge, so its objects reach Apple's spatial audio path instead of the bridge's
/// E-AC-3 or FLAC bed.
///
/// This is the arrangement of SpatialAudioBridge's `APACStream`, fed by a demuxer of the engine's own
/// (`docs/architecture.md` there, "The segment grid"): segment N always covers N × 3.2 s up to
/// (N + 1) × 3.2 s, two APAC sync periods, whichever conversion run produced it. A request the
/// current run will not reach soon restarts conversion at that segment, so seeking is a request like
/// any other, and segments from different runs share one initialization segment and one timeline.
///
/// The output timeline is the video's: an audio packet at source time `t` lands at `t - offset`,
/// where `offset` is the shift the first producer's mux applies to every packet it writes
/// (`setSourceOffset`). That is exactly where the bridged audio would have been muxed.
@available(tvOS 26, iOS 26, macOS 26, *)
final class SpatialAudioRendition: SpatialAudioSegmentSource, @unchecked Sendable {
    /// Two sync periods of 75 APAC packets: 3.2 s at 48 kHz.
    static let segmentFrames: Int64 = 2 * 75 * 1024
    /// Segments converted ahead of the newest request, and kept behind it for skipping back.
    static let lookahead = 6
    static let keptBehind = 20
    /// How long a request waits for its segment. The server answers a slow one with early headers.
    static let requestTimeout: TimeInterval = 30
    /// How far before a segment's start a run seeks, because audio sits near, not exactly at, the
    /// video keyframes a seek lands on.
    static let seekLeadSeconds = 2.0
    /// How far before a segment's start a run may begin decoding.
    static let syncSearchSeconds = 0.5
    /// Transport failures in a row (demuxer open, seek or read) before the rendition gives up.
    static let maxConsecutiveFailures = 3

    let kind: SpatialAudioTrackKind
    let segmentCount: Int
    let mediaPlaylist: String
    var codecs: String { configuration.layout.apacCodecString }
    var channelCount: Int { configuration.layout.channelCount }
    var bitRate: Int { configuration.bitRate }
    var pipelineDescription: String {
        "\(kind.spatialLabel) → APAC \(configuration.layout == .nineOneSix ? "9.1.6" : "7.1.4") (Spatial Audio)"
    }

    /// Called once, off the main thread, when conversion fails for good: the library rejected the
    /// track, or the source stopped answering. The session then has no audio to serve.
    var onFailure: (@Sendable (String) -> Void)?

    private let codec: SpatialAudioCodec
    private let configuration = SpatialAudioRendition.liveConfiguration
    private let totalFrames: Int64
    private let reader: SpatialAudioPacketReader

    /// The offline profile would hold every segment back by about 20 s of audio.
    private static var liveConfiguration: APACConfiguration {
        var configuration = APACConfiguration()
        configuration.liveEncoding = true
        return configuration
    }

    /// The installed encoder's priming, 2048 frames on tested systems. Queried once per process, and
    /// only for a track that passed the check: creating the APAC converter it takes costs 80 to
    /// 380 ms on a Mac, while the library refuses a plain TrueHD or DTS-HD MA track in about 1 ms.
    private static let primingFrames: Int64? = try? liveConfiguration.encoderPrimingDuration().value

    private static func priming() throws -> Int64 {
        guard let primingFrames else { throw SpatialAudioError.encoding("The APAC encoder reports no priming") }
        return primingFrames
    }

    private struct Run {
        let id: UUID
        /// The first segment the run delivers.
        let start: Int
        let started = Date()
        var produced = -1
        var ended = false
        var task: Task<Void, Never>?
    }

    private let condition = NSCondition()
    private var sourceOffset: Double?
    private var initData: Data?
    private var segments: [Int: Data] = [:]
    private var window = 0..<Int.max
    private var requested = 0
    /// Segments that requests are waiting for, one entry per request.
    private var waiting: [Int] = []
    private var run: Run?
    private var failure: String?
    private var consecutiveFailures = 0
    private var stopped = false

    /// `durationSeconds` is the video playlist's, so both renditions describe one timeline.
    init(kind: SpatialAudioTrackKind, durationSeconds: Double, reader: SpatialAudioPacketReader) {
        self.kind = kind
        codec = kind == .trueHD ? .trueHDAtmos : .dtsX
        totalFrames = max(1, Int64((durationSeconds * 48_000).rounded(.up)))
        segmentCount = Int((totalFrames + Self.segmentFrames - 1) / Self.segmentFrames)
        mediaPlaylist = Self.mediaPlaylist(totalFrames: totalFrames)
        self.reader = reader
    }

    static func mediaPlaylist(totalFrames: Int64) -> String {
        let count = Int((totalFrames + segmentFrames - 1) / segmentFrames)
        let target = Int((Double(segmentFrames) / 48_000).rounded(.up))
        var lines = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-TARGETDURATION:\(target)", "#EXT-X-MEDIA-SEQUENCE:0",
                     "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-MAP:URI=\"apac_init.mp4\""]
        for index in 0..<count {
            let frames = min(segmentFrames, totalFrames - Int64(index) * segmentFrames)
            lines.append(String(format: "#EXTINF:%.6f,", locale: Locale(identifier: "en_US_POSIX"),
                                Double(frames) / 48_000))
            lines.append("apac\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The segment holding output time `seconds`.
    func index(atSeconds seconds: Double) -> Int {
        let frame = Int64((max(seconds, 0) * 48_000).rounded(.down))
        return Int(min(frame, totalFrames - 1) / Self.segmentFrames)
    }

    // MARK: - Session wiring

    /// The first producer's mux shift, in seconds on the source clock. Later producers that report
    /// another value are only logged: segments already converted keep the first.
    func setSourceOffset(_ seconds: Double) {
        condition.lock()
        defer { condition.unlock() }
        guard let current = sourceOffset else {
            sourceOffset = seconds
            condition.broadcast()
            return
        }
        if abs(current - seconds) > 0.001 {
            EngineLog.emit(
                "[SpatialAudio] a producer muxes at offset \(String(format: "%.3f", seconds)) s, the rendition "
                + "keeps \(String(format: "%.3f", current)) s", category: .audioBridge)
        }
    }

    /// Starts converting the segment at `seconds` before AVPlayer asks for it.
    func prepare(atSeconds seconds: Double) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, failure == nil, run == nil else { return }
        requested = index(atSeconds: seconds)
        restartLocked(at: requested)
    }

    /// Decodes about a second of the track from `sourceSeconds`, throwing what a conversion run would
    /// throw on a track the library cannot render. Leaves the reader open for the runs.
    func validate(fromSourceSeconds sourceSeconds: Double) async throws {
        try reader.seek(toSourceSeconds: sourceSeconds - Self.seekLeadSeconds)
        var session: SpatialAudioTranscoder?
        var first: Double?
        var packets = 0
        while let packet = try reader.next() {
            try Task.checkCancellation()
            packets += 1
            if session == nil {
                guard let offset = kind.syncOffset(in: packet.data) else {
                    if packets > 2_000 { throw SpatialAudioError.source("No sync point in 2000 packets") }
                    continue
                }
                session = try SpatialAudioTranscoder(codec: codec, destination: .segments(onSegment: { _ in }),
                                                     configuration: configuration)
                first = packet.seconds
                try await session?.append(packet.data.dropFirst(offset))
                continue
            }
            try await session?.append(packet.data)
            if let first, let seconds = packet.seconds, seconds - first >= 1 { break }
            if packets > 4_000 { break }
        }
        await session?.cancel()
        guard session != nil else { throw SpatialAudioError.source("The track has no audio from here") }
        _ = try Self.priming()
    }

    /// Stops conversion and answers every request still waiting. The reader closes once the run
    /// that holds it has returned.
    func shutdown() {
        condition.lock()
        stopped = true
        let task = run?.task
        run = nil
        segments = [:]
        condition.broadcast()
        condition.unlock()
        task?.cancel()
        reader.interrupt()
        let reader = self.reader
        BlockingWork.detached(priority: .utility) {
            await task?.value
            reader.close()
        }
    }

    // MARK: - Requests

    func initSegment() -> Data? {
        condition.lock()
        defer { condition.unlock() }
        if let initData { return initData }
        guard !stopped, failure == nil else { return nil }
        if run?.ended ?? true { restartLocked(at: requested) }
        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        while initData == nil {
            guard !stopped, failure == nil, run?.ended == false, condition.wait(until: deadline) else {
                return initData
            }
        }
        return initData
    }

    func segment(at index: Int) -> Data? {
        guard (0..<segmentCount).contains(index) else { return nil }
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, failure == nil else { return nil }
        requested = index
        keepSegmentsLocked(around: index)
        if let data = segments[index] { return data }
        if !waitsForRunLocked(index) {
            EngineLog.emit(
                "[SpatialAudio] apac\(index) restarts conversion (run from \(run?.start ?? -1) "
                + "converted \(run?.produced ?? -1))", category: .audioBridge)
            restartLocked(at: index)
            keepSegmentsLocked(around: index)
        }
        let started = Date()
        waiting.append(index)
        defer { if let entry = waiting.firstIndex(of: index) { waiting.remove(at: entry) } }
        let deadline = started.addingTimeInterval(Self.requestTimeout)
        while segments[index] == nil {
            // A later request moved conversion elsewhere, or the run ended without this segment.
            guard !stopped, failure == nil, waitsForRunLocked(index) else { return nil }
            guard condition.wait(until: deadline) else {
                EngineLog.emit("[SpatialAudio] apac\(index) timed out", category: .audioBridge)
                return segments[index]
            }
        }
        let waited = Date().timeIntervalSince(started)
        if waited > 0.05 {
            EngineLog.emit("[SpatialAudio] apac\(index) after \(Int(waited * 1000)) ms",
                           category: .audioBridge, level: .verbose)
        }
        return segments[index]
    }

    /// Whether the current run will deliver `index` sooner than a new run would. A new run delivers
    /// its first segment in about two segments' conversion time, and AVPlayer abandons a seek whose
    /// first segment takes much over 3 s, so a request waits only up to two segments past the
    /// converted point (`APACStream`'s rule).
    private func waitsForRunLocked(_ index: Int) -> Bool {
        guard let run, !run.ended else { return false }
        return index >= run.start && index > run.produced && index <= max(run.start + 1, run.produced + 2)
    }

    /// The furthest segment playback wants: the latest request, or a waiting one further ahead.
    private var frontierLocked: Int { max(requested, waiting.max() ?? requested) }

    private func keepSegmentsLocked(around index: Int) {
        window = max(0, index - Self.keptBehind)..<(max(index, frontierLocked) + Self.lookahead + 3)
        segments = segments.filter { window.contains($0.key) }
    }

    private func restartLocked(at index: Int) {
        let previous = run?.task
        previous?.cancel()
        let id = UUID()
        run = Run(id: id, start: index)
        // One reader, so a run starts once the one before it has let go of it.
        run?.task = BlockingWork.detached(priority: .userInitiated) { [weak self] in
            await previous?.value
            await self?.convert(from: index, run: id)
        }
    }

    // MARK: - Conversion

    private func convert(from index: Int, run id: UUID) async {
        do {
            guard let offset = awaitSourceOffset(run: id) else { return end(run: id, failure: nil) }
            let priming = try Self.priming()
            // Decoding starts at the last sync point before the segment's first presented sample,
            // which follows the encoder priming, so the run's first fragment begins on the grid.
            let start = CMTime(value: Int64(index) * Self.segmentFrames + priming, timescale: 48_000)
            try reader.seek(toSourceSeconds: start.seconds + offset - Self.seekLeadSeconds)
            var session: SpatialAudioTranscoder?
            var reachesEnd = true
            while let packet = try reader.next() {
                try Task.checkCancellation()
                var data = packet.data
                var time = packet.seconds.map { CMTime(seconds: $0 - offset, preferredTimescale: 48_000) }
                if session == nil {
                    // The seek lands on a video keyframe, up to a GOP before the target. Packets
                    // up to just before the start are skipped rather than decoded and discarded:
                    // TrueHD repeats its major sync every few dozen access units and every DTS
                    // frame opens on a core sync, so one follows within half a second.
                    guard let first = time, first.seconds > start.seconds - Self.syncSearchSeconds,
                          let sync = kind.syncOffset(in: data) else { continue }
                    if sync > 0 {
                        time = CMTime(seconds: first.seconds + kind.skippedSeconds(in: data, before: sync),
                                      preferredTimescale: 48_000)
                        data = data.dropFirst(sync)
                    }
                    session = try transcoder(start: start, inputStart: time, run: id)
                }
                try await session?.append(data, time: time)
                guard await proceeds(run: id) else { reachesEnd = false; break }
            }
            if reachesEnd {
                // A run that reached the end of the source pads the rest of the playlist, which follows
                // the video and may outlast the track, with silence.
                let session = try session ?? transcoder(start: start, inputStart: nil, run: id)
                _ = try await session.finish(paddingTo: CMTime(value: max(totalFrames, start.value + 1), timescale: 48_000))
            } else {
                await session?.cancel()
            }
            end(run: id, failure: nil)
        } catch is CancellationError {
            end(run: id, failure: nil)
        } catch {
            end(run: id, failure: error)
        }
    }

    private func transcoder(start: CMTime, inputStart: CMTime?, run id: UUID) throws -> SpatialAudioTranscoder {
        var configuration = self.configuration
        configuration.startTime = start
        configuration.inputStartTime = inputStart
        return try SpatialAudioTranscoder(
            codec: codec,
            destination: .segments(onSegment: { [weak self] in self?.deliver($0, run: id) }),
            configuration: configuration)
    }

    /// The offset arrives when the first producer opens its gate, which the pump does right after
    /// `start()`; until then a run has no place on the timeline.
    private func awaitSourceOffset(run id: UUID) -> Double? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        while sourceOffset == nil {
            guard run?.id == id, !stopped, !Task.isCancelled, Date() < deadline else { return nil }
            _ = condition.wait(until: min(deadline, Date().addingTimeInterval(0.1)))
        }
        return run?.id == id ? sourceOffset : nil
    }

    /// Whether run `id` carries on, holding it while it is `lookahead` segments past what playback wants.
    private func proceeds(run id: UUID) async -> Bool {
        while true {
            let (current, ahead): (Bool, Bool) = condition.withLock {
                guard let run, run.id == id, !stopped else { return (false, false) }
                return (true, run.produced >= frontierLocked + Self.lookahead)
            }
            guard current, !Task.isCancelled else { return false }
            guard ahead else { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Stores a fragment under the grid index of its start time. Called serially on an AVFoundation
    /// queue; fragments of a run that was replaced are dropped.
    private func deliver(_ segment: APACSegment, run id: UUID) {
        condition.lock()
        defer { condition.unlock() }
        guard var current = run, current.id == id else { return }
        switch segment.kind {
        case .initialization:
            // Every run writes the same initialization apart from creation times.
            if initData == nil { initData = segment.data }
        case .media:
            guard let start = segment.startTime else { return }
            let index = Int((start.seconds * 48_000 / Double(Self.segmentFrames)).rounded())
            guard index >= current.start else { return }
            if window.contains(index), segments[index] == nil { segments[index] = segment.data }
            if current.produced < current.start {
                EngineLog.emit(
                    "[SpatialAudio] the run from apac\(current.start) delivered its first segment after "
                    + "\(Int(Date().timeIntervalSince(current.started) * 1000)) ms", category: .audioBridge)
            }
            current.produced = max(current.produced, index)
            consecutiveFailures = 0
            run = current
        }
        condition.broadcast()
    }

    private func end(run id: UUID, failure error: (any Error)?) {
        condition.lock()
        guard var current = run, current.id == id else { return condition.unlock() }
        current.ended = true
        run = current
        var terminal: String?
        if let error, !stopped {
            consecutiveFailures += 1
            // The library's verdicts repeat on every run; a transport failure may not.
            if error is SpatialAudioError || consecutiveFailures >= Self.maxConsecutiveFailures {
                failure = String(describing: error)
                terminal = failure
            }
            EngineLog.emit(
                "[SpatialAudio] the run from apac\(current.start) failed"
                + (terminal == nil ? " (\(consecutiveFailures) in a row, retrying on the next request)" : "")
                + ": \(error)", category: .audioBridge)
        }
        condition.broadcast()
        condition.unlock()
        if let terminal { onFailure?(terminal) }
    }
}
#endif
