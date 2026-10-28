import AVFoundation
import Foundation

/// Silent-audio keep-alive for the on-device pairing window.
///
/// Pairing forces the user to leave this app and tap through
/// Settings › Privacy & Security › Developer Mode. Without a
/// background mode iOS suspends the app seconds after it leaves the
/// foreground: the Bonjour advertisement dies, the Rust pairing host
/// freezes mid-handshake, and its completion never lands — the
/// system side can even finish pairing while the app still shows
/// "waiting". (First seen on device with run #21.)
///
/// While the host is up we therefore play a fully silent loop
/// through an `AVAudioEngine` — no audio file, the PCM buffer is
/// zero-filled in code — under the `audio` background mode declared
/// in Info.plist. The session mixes with others and outputs pure
/// silence, so nothing is audible. `stop()` is called the moment
/// pairing finishes, fails, or is discarded: the keep-alive never
/// outlives the pairing window.
@MainActor
final class PairingKeepAlive {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var running = false

    func start() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            if player.engine == nil {
                engine.attach(player)
            }
            let format = engine.outputNode.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                // No usable output format; the active audio session
                // alone still keeps the process schedulable.
                running = true
                return
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)

            // One second of digital silence, looped.
            let frames = AVAudioFrameCount(format.sampleRate)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
                running = true
                return
            }
            buffer.frameLength = frames
            if let channelData = buffer.floatChannelData {
                for channel in 0..<Int(format.channelCount) {
                    channelData[channel].update(repeating: 0, count: Int(frames))
                }
            }

            if !engine.isRunning {
                try engine.start()
            }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            running = true
        } catch {
            running = false
            NSLog("[cocowall] pairing keep-alive failed to start: %@",
                  error.localizedDescription)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        player.stop()
        if engine.isRunning {
            engine.stop()
        }
        if player.engine != nil {
            engine.detach(player)
        }
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
