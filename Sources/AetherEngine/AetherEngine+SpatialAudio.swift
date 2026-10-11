import AVFoundation
import Foundation
#if canImport(SpatialAudioPlayback)
import SpatialAudioPlayback
#endif

/// TrueHD Atmos and DTS:X as Apple spatial audio (`LoadOptions.spatialAudio`). The session serves the
/// APAC rendition; the engine keeps the receiver in Atmos while it plays and falls back to the bridge
/// when conversion fails mid-session.
extension AetherEngine {

    /// The session's APAC rendition stopped converting: the library rejected the track partway in, or
    /// the source stopped answering its reader. Nothing inside the session recovers that, so it is
    /// rebuilt at the same position with the stream on the audio bridge (AE#641's shape).
    @MainActor
    func abandonSpatialAudio(streamIndex: Int32, reason: String) async {
        guard spatialAudioRefusedStreamIndices.insert(streamIndex).inserted else { return }
        EngineLog.emit(
            "[AetherEngine] spatial audio for stream \(streamIndex) failed (\(reason)); rebuilding the "
            + "session on the audio bridge", category: .engine)
        do {
            try await startTakeoverRebuild { _ in }.value
            EngineLog.emit("[AetherEngine] rebuilt on the audio bridge: \(nativeVideoSession?.audioPipelineDescription ?? "no audio")",
                           category: .engine)
        } catch is CancellationError {
            EngineLog.emit("[AetherEngine] spatial audio fallback superseded; nothing to do", category: .engine)
        } catch {
            EngineLog.emit("[AetherEngine] spatial audio fallback refused (\(error))", category: .engine)
        }
    }

    /// A master the session cannot keep (an AVPlayer rejection, the #35 readiness gate, an AirPlay
    /// receiver) falls back to the media playlist, which has no audio while the APAC rendition carries
    /// it. Such a session is rebuilt on the bridge instead, and its own fallbacks then apply as before.
    /// Returns true when it took over.
    @MainActor
    func abandonSpatialAudioInsteadOfMediaFallback(_ session: HLSVideoEngine, reason: String) -> Bool {
        guard session.servesSpatialAudio, session.activeAudioSourceStreamIndex >= 0 else { return false }
        let streamIndex = session.activeAudioSourceStreamIndex
        Task { @MainActor [weak self] in
            await self?.abandonSpatialAudio(streamIndex: streamIndex, reason: reason)
        }
        return true
    }

    /// Plays `AtmosOutputActivator`'s silent Dolby Atmos stream beside `player` while it plays this
    /// session's items: on the tested Apple TV, APAC alone left the HDMI output in multichannel PCM.
    /// tvOS only. The stream is there for that HDMI switch, and on iOS and macOS a second unmuted
    /// player beside the engine's would compete with it for Now Playing and the audio session for no
    /// gain. The engine configures the audio session itself and leaves activation to AVKit (#24), so
    /// the activator's own `configureAudioSession()` is not used.
    @MainActor
    func attachAtmosOutputActivator(to player: AVPlayer, session: HLSVideoEngine) {
        #if canImport(SpatialAudioPlayback) && os(tvOS)
        guard #available(tvOS 26, iOS 26, macOS 26, *), session.servesSpatialAudio,
              let base = session.masterPlaylistURL?.deletingLastPathComponent().path else {
            return detachAtmosOutputActivator()
        }
        let activator = atmosOutputActivator as? AtmosOutputActivator ?? AtmosOutputActivator()
        atmosOutputActivator = activator
        // The path carries the session token, whichever address (loopback or LAN) the item uses.
        activator.attach(to: player) { item in
            (item.asset as? AVURLAsset)?.url.path.hasPrefix(base) == true
        }
        #endif
    }

    @MainActor
    func detachAtmosOutputActivator() {
        #if canImport(SpatialAudioPlayback)
        if #available(tvOS 26, iOS 26, macOS 26, *) {
            (atmosOutputActivator as? AtmosOutputActivator)?.detach()
        }
        #endif
        atmosOutputActivator = nil
    }
}
