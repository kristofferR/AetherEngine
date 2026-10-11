import Testing
import Foundation
import AetherLibavcodec
@testable import AetherEngine

/// TrueHD Atmos and DTS:X served as an APAC rendition beside a video-only variant
/// (`LoadOptions.spatialAudio`). The conversion itself is SpatialAudioBridge's; these pin what the
/// engine decides around it and what it serves.
@Suite(.offCooperativePool)
struct SpatialAudioRenditionTests {

    // MARK: - Which tracks

    /// The library decides Atmos and DTS:X as decoding starts; FFmpeg's profile cannot, since it reports
    /// alternate DTS:X presentations as plain DTS-HD MA.
    @Test("every 48 kHz TrueHD and DTS-HD MA track is offered, nothing else")
    func candidateTracks() {
        for profile in [AV_PROFILE_TRUEHD_ATMOS, AV_PROFILE_UNKNOWN] {
            #expect(SpatialAudioTrackKind(codecID: AV_CODEC_ID_TRUEHD, profile: profile, sampleRate: 48_000) == .trueHD)
        }
        for profile in [AV_PROFILE_DTS_HD_MA, AV_PROFILE_DTS_HD_MA_X, AV_PROFILE_DTS_HD_MA_X_IMAX] {
            #expect(SpatialAudioTrackKind(codecID: AV_CODEC_ID_DTS, profile: profile, sampleRate: 48_000) == .dtsHDMA)
        }
        // The library renders 48 kHz only.
        #expect(SpatialAudioTrackKind(codecID: AV_CODEC_ID_TRUEHD, profile: AV_PROFILE_TRUEHD_ATMOS, sampleRate: 96_000) == nil)
        for profile in [AV_PROFILE_DTS, AV_PROFILE_DTS_HD_HRA, AV_PROFILE_DTS_EXPRESS] {
            #expect(SpatialAudioTrackKind(codecID: AV_CODEC_ID_DTS, profile: profile, sampleRate: 48_000) == nil)
        }
        #expect(SpatialAudioTrackKind(codecID: AV_CODEC_ID_EAC3, profile: 30, sampleRate: 48_000) == nil)
    }

    /// The library refuses a TrueHD stream that does not open on a major sync ("stream skipped
    /// bytes"), and a packet can hold several access units.
    @Test("a run starts on the first TrueHD major sync inside a packet, and on a DTS core sync")
    func syncPoints() {
        // Access units: a 4-byte header whose low 12 bits of the first word give the length in words.
        let plain: [UInt8] = [0x00, 0x04, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44]
        let major: [UInt8] = [0x00, 0x06, 0x00, 0x00, 0xF8, 0x72, 0x6F, 0xBA, 0, 0, 0, 0]
        let packet = Data(plain + major)
        #expect(SpatialAudioTrackKind.trueHD.syncOffset(in: packet) == plain.count)
        #expect(SpatialAudioTrackKind.trueHD.skippedSeconds(in: packet, before: plain.count) == 40.0 / 48_000)
        #expect(SpatialAudioTrackKind.trueHD.syncOffset(in: Data(major)) == 0)
        #expect(SpatialAudioTrackKind.trueHD.syncOffset(in: Data(plain)) == nil)
        #expect(SpatialAudioTrackKind.dtsHDMA.syncOffset(in: Data([0x7F, 0xFE, 0x80, 0x01, 0x00])) == 0)
        #expect(SpatialAudioTrackKind.dtsHDMA.syncOffset(in: Data(plain)) == nil)
    }

    // MARK: - When the session serves it

    private func inputs(_ change: (inout SpatialAudioEligibility.Inputs) -> Void = { _ in }) -> SpatialAudioEligibility.Inputs {
        var inputs = SpatialAudioEligibility.Inputs(
            allowed: true, track: .trueHD, refusedEarlier: false, isLive: false, sequentialOrigin: false,
            heldSourceConnection: false, originIsSerial: false, isDiscSource: false, demuxedAudio: false,
            secondReaderAvailable: true, masterRoutable: true)
        change(&inputs)
        return inputs
    }

    @Test("the rendition needs a second reader, a master, and a track the library has not refused")
    func eligibility() {
        #expect(SpatialAudioEligibility.absentReason(inputs()) == nil)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.allowed = false }) == .notAllowed)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.track = nil }) == .notConvertible)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.refusedEarlier = true }) == .refusedEarlier)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.isLive = true }) == .live)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.originIsSerial = true }) == .serialOrigin)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.isDiscSource = true }) == .discSource)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.secondReaderAvailable = false }) == .noSecondReader)
        #expect(SpatialAudioEligibility.absentReason(inputs { $0.masterRoutable = false }) == .mediaPlaylistRouting)
    }

    #if canImport(SpatialAudioBridge)
    @Test("the playlist covers the video's duration on the 3.2 s grid")
    @available(tvOS 26, iOS 26, macOS 26, *)
    func mediaPlaylist() {
        let text = SpatialAudioRendition.mediaPlaylist(totalFrames: 2 * SpatialAudioRendition.segmentFrames + 48_000)
        let durations = text.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }
        #expect(durations == ["#EXTINF:3.200000,", "#EXTINF:3.200000,", "#EXTINF:1.000000,"])
        #expect(text.contains("#EXT-X-TARGETDURATION:4\n"))
        #expect(text.contains("#EXT-X-MAP:URI=\"apac_init.mp4\"\n"))
        #expect(text.contains("apac2.m4s\n#EXT-X-ENDLIST\n"))
    }
    #endif

    // MARK: - What the master and the server say

    private final class StubSource: SpatialAudioSegmentSource, @unchecked Sendable {
        let codecs = "apac.31.03"
        let channelCount = 12
        let bitRate = 3_072_000
        let mediaPlaylist = "#EXTM3U\n#EXT-X-ENDLIST\n"
        let pipelineDescription = "stub"
        var delay: TimeInterval = 0
        func initSegment() -> Data? { Data("init".utf8) }
        func segment(at index: Int) -> Data? {
            Thread.sleep(forTimeInterval: delay)
            return index < 4 ? Data(repeating: UInt8(index), count: 70_000) : nil
        }
        func setSourceOffset(_ seconds: Double) {}
        func prepare(atSeconds seconds: Double) {}
        func shutdown() {}
    }

    private func provider(language: String?) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 4, backwardWindow: 4),
            segments: [HLSVideoEngine.Segment(startPts: 0, endPts: 4000, startSeconds: 0, durationSeconds: 4)],
            codecsString: "hvc1.2.4.L150.b0,apac.31.03", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 40_000_000, audioLanguage: language, audioChannelCount: 12,
            audioIsAtmosStreamCopy: false)
    }

    @Test("the master lists the APAC rendition by URI, untagged or not")
    func masterRendition() {
        let tagged = provider(language: "eng")
        tagged.setSpatialAudioSource(StubSource())
        let audio = HLSLocalServer.buildMasterPlaylistText(provider: tagged)
            .split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") }
        #expect(audio?.hasSuffix("LANGUAGE=\"eng\",DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"12\",URI=\"apac.m3u8\"") == true)

        // Its segments are the only audio the session has, so an untagged track needs the tag too.
        let untagged = provider(language: nil)
        #expect(untagged.masterAudioRendition == nil)
        untagged.setSpatialAudioSource(StubSource())
        let master = HLSLocalServer.buildMasterPlaylistText(provider: untagged)
        #expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"Spatial Audio\","
            + "DEFAULT=YES,AUTOSELECT=YES,CHANNELS=\"12\",URI=\"apac.m3u8\""))
        #expect(master.contains("CODECS=\"hvc1.2.4.L150.b0,apac.31.03\""))
        #expect(master.contains("AUDIO=\"aud\""))
    }

    @Test("the server answers the APAC playlist, init and segments, and a slow segment arrives whole")
    func serverRoutes() throws {
        let source = StubSource()
        let prov = provider(language: nil)
        prov.setSpatialAudioSource(source)
        let server = HLSLocalServer(provider: prov)
        try server.start()
        defer { server.stop() }
        let base = try #require(server.playlistURL?.deletingLastPathComponent())

        #expect(try String(contentsOf: base.appendingPathComponent("apac.m3u8"), encoding: .utf8) == source.mediaPlaylist)
        #expect(try Data(contentsOf: base.appendingPathComponent("apac_init.mp4")) == Data("init".utf8))
        #expect(try Data(contentsOf: base.appendingPathComponent("apac3.m4s")) == Data(repeating: 3, count: 70_000))
        #expect(throws: (any Error).self) { try Data(contentsOf: base.appendingPathComponent("apac9.m4s")) }

        // Past the 2 s threshold the headers go out early and the body follows when it lands.
        source.delay = 2.3
        #expect(try Data(contentsOf: base.appendingPathComponent("apac1.m4s")) == Data(repeating: 1, count: 70_000))
    }
}
