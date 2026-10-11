#if canImport(SpatialAudioBridge) && os(macOS)
import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// A whole session over a real TrueHD Atmos or DTS:X file. Such media cannot ship with the repository,
/// so the test runs when `AETHER_SPATIAL_AUDIO_FIXTURE` names one (SpatialAudioBridge's fixture tests
/// take the same approach).
@Suite(.offCooperativePool, .serialized)
struct SpatialAudioSessionTests {
    static let fixture = ProcessInfo.processInfo.environment["AETHER_SPATIAL_AUDIO_FIXTURE"]

    /// 3.2 s at the APAC track's 48 kHz timescale.
    static let segmentTicks: UInt64 = 153_600

    @Test("the audio plays as APAC on the 3.2 s grid, a restarted run included",
          .enabled(if: fixture != nil, "set AETHER_SPATIAL_AUDIO_FIXTURE to a TrueHD Atmos or DTS:X MKV"),
          .timeLimit(.minutes(2)))
    @available(macOS 26, *)
    func servesAPAC() async throws {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: try #require(Self.fixture)), dvModeAvailable: false)
        let playbackURL = try engine.start()
        defer { engine.stop() }
        #expect(engine.servesSpatialAudio)
        #expect(engine.audioPipelineDescription?.hasSuffix("→ APAC 7.1.4 (Spatial Audio)") == true)
        let master = try String(contentsOf: playbackURL, encoding: .utf8)
        #expect(master.contains("URI=\"apac.m3u8\""))
        #expect(master.contains(",apac.31.03\""))

        let base = playbackURL.deletingLastPathComponent()
        func segment(_ index: Int) throws -> Data {
            try Data(contentsOf: base.appendingPathComponent("apac\(index).m4s"))
        }
        var file = try Data(contentsOf: base.appendingPathComponent("apac_init.mp4"))
        for index in 0...1 {
            let data = try segment(index)
            #expect(Self.firstTfdt(data) == UInt64(index) * Self.segmentTicks)
            file.append(data)
        }
        // Outside the converted range: a new run, on the same grid.
        #expect(Self.firstTfdt(try segment(9)) == 9 * Self.segmentTicks)

        // The bytes are APAC that AVFoundation decodes to 7.1.4, priming trimmed.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apac-\(UUID().uuidString).mp4")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let (channels, frames) = try await Self.decode(url)
        #expect(channels == 12)
        #expect(frames == 2 * Int(Self.segmentTicks) - 2048)
    }

    /// The first `tfdt` in a fragment.
    static func firstTfdt(_ data: Data) -> UInt64? {
        let bytes = [UInt8](data)
        func u32(_ o: Int) -> UInt32 { bytes[o..<o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
        func find(_ type: String, in range: Range<Int>) -> Range<Int>? {
            var offset = range.lowerBound
            while offset + 8 <= range.upperBound {
                let size = Int(u32(offset))
                guard size >= 8, offset + size <= range.upperBound else { return nil }
                if String(bytes: bytes[offset + 4..<offset + 8], encoding: .isoLatin1) == type {
                    return offset + 8..<offset + size
                }
                offset += size
            }
            return nil
        }
        guard let moof = find("moof", in: 0..<bytes.count), let traf = find("traf", in: moof),
              let tfdt = find("tfdt", in: traf) else { return nil }
        let start = tfdt.lowerBound
        return bytes[start] == 1
            ? UInt64(u32(start + 4)) << 32 | UInt64(u32(start + 8))
            : UInt64(u32(start + 4))
    }

    static func decode(_ url: URL) async throws -> (channels: Int, frames: Int) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        reader.add(output)
        #expect(reader.startReading())
        var channels = 0
        var frames = 0
        while let buffer = output.copyNextSampleBuffer() {
            if let format = CMSampleBufferGetFormatDescription(buffer),
               let description = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
                channels = Int(description.pointee.mChannelsPerFrame)
            }
            frames += CMSampleBufferGetNumSamples(buffer)
        }
        #expect(reader.status == .completed)
        return (channels, frames)
    }
}
#endif
