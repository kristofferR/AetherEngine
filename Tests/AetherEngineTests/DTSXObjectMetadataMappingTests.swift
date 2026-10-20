// Only with the DTSXObjectAudio trait (off by default): the decoder is not built without it.
#if DTSXObjectAudio
import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// FFmpeg's dca decoder returns DTS:X's standard presentation as 7.1.4 (FFmpegBuild's `x_heights`
/// patch), and `DTSXObjectAudioDecoder` names its channels. These pin what a listener would hear
/// wrong: a bed or height channel on the wrong speaker, or a channel outside the twelve slipping
/// through to be panned.
@Suite("DTS:X channels map onto the renderer's speakers")
struct DTSXObjectMetadataMappingTests {

    @Test("bed and height channels route to the matching speaker, LFE to LFE")
    func speakerRoles() {
        let expected: [(AVChannel, ObjectAudioRole)] = [
            (AV_CHAN_FRONT_CENTER, .bed(.center)), (AV_CHAN_FRONT_LEFT, .bed(.left)),
            (AV_CHAN_FRONT_RIGHT, .bed(.right)), (AV_CHAN_SIDE_LEFT, .bed(.sideLeft)),
            (AV_CHAN_SIDE_RIGHT, .bed(.sideRight)), (AV_CHAN_LOW_FREQUENCY, .lfe),
            (AV_CHAN_BACK_LEFT, .bed(.rearLeft)), (AV_CHAN_BACK_RIGHT, .bed(.rearRight)),
            (AV_CHAN_TOP_FRONT_LEFT, .bed(.topFrontLeft)), (AV_CHAN_TOP_FRONT_RIGHT, .bed(.topFrontRight)),
            (AV_CHAN_TOP_BACK_LEFT, .bed(.topRearLeft)), (AV_CHAN_TOP_BACK_RIGHT, .bed(.topRearRight)),
        ]
        #expect(DTSXObjectAudioDecoder.channels.count == expected.count)
        for ((channel, role), (wantChannel, wantRole)) in zip(DTSXObjectAudioDecoder.channels, expected) {
            #expect(channel == wantChannel && role == wantRole, "\(channel.rawValue)")
        }
    }

    @Test("the standard channels play one to one on 7.1.4 and 9.1.6, and only there")
    func oneToOneLayouts() {
        for layout in SpatialSpeakerLayout.allCases {
            #expect(layout.carriesDTSXOneToOne == (layout == .l714 || layout == .l916), "\(layout.rawValue)")
        }
    }

    @Test("a channel plays at unity on its speaker")
    func channelState() {
        let state = DTSXObjectAudioDecoder.state(for: .bed(.topFrontLeft))
        #expect(state.position == SpatialSpeaker.topFrontLeft.position)
        #expect(state.gain == 1)
        #expect(DTSXObjectAudioDecoder.state(for: .lfe).gain == 1)
    }

    @Test("a presentation FFmpeg labels DTS:X without readable heights plays its 7.1; others are refused")
    func verdictWithoutHeights() {
        let bed = DTSXObjectAudioDecoder.channels.prefix(DTSXObjectAudioDecoder.bedChannelCount).map(\.0)
        let verdict = DTSXObjectAudioDecoder.verdictWithoutHeights
        #expect(verdict(AV_PROFILE_DTS_HD_MA_X_IMAX, bed, "imax") == .bed("imax"))
        #expect(verdict(AV_PROFILE_DTS_HD_MA_X, bed, "x") == .bed("x"))
        #expect(verdict(AV_PROFILE_DTS_HD_MA, bed, "plain") == .refused("plain"))
        #expect(verdict(AV_PROFILE_DTS_HD_MA_X_IMAX, bed + [AV_CHAN_WIDE_LEFT], "wide") == .refused("wide"))
        #expect(verdict(AV_PROFILE_DTS_HD_MA_X_IMAX, [], "empty") == .refused("empty"))
    }

    @Test("the bed a 7.1-only DTS:X stream plays is the 7.1 at the head of the channels, no height in it")
    func bedRoles() {
        #expect(DTSXObjectAudioDecoder.bedRoles == [
            .bed(.center), .bed(.left), .bed(.right), .bed(.sideLeft), .bed(.sideRight), .lfe,
            .bed(.rearLeft), .bed(.rearRight),
        ])
    }

    @Test("the decoder opens, takes input and asks for more")
    func decoderLifecycle() throws {
        let decoder = try DTSXObjectAudioDecoder()
        try [UInt8](repeating: 0, count: 64).withUnsafeBytes { try decoder.push($0) }
        #expect(try decoder.nextBlock() == nil)
        decoder.releaseHeldBlocks()
        #expect(try decoder.nextBlock() == nil)
        decoder.reset()
        #expect(decoder.selfResetCount == 0)
    }

    @Test("input with no DTS frame in it gives no verdict, so the session keeps the channel bridge")
    func verdictOnNonDTS() throws {
        let decoder = try DTSXObjectAudioDecoder()
        let garbage = [UInt8](repeating: 0x55, count: 1 << 20)
        #expect(garbage.withUnsafeBytes { decoder.verdict(feeding: $0) } == nil)
    }
}
#endif
