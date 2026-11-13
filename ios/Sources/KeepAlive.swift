import AVFoundation

// Plays a silent sound on a loop. Apple lets apps that play audio keep running with the screen locked,
// which is what keeps the helper checking SyncHub in the background.
final class KeepAlive {
    private var player: AVAudioPlayer?

    func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: KeepAlive.silentWav())
            p.numberOfLoops = -1
            p.volume = 1.0
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            player = nil
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // After a call or alarm, start the silence again.
            if let v = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               AVAudioSession.InterruptionType(rawValue: v) == .ended {
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.player?.play()
            }
        }
    }

    var isPlaying: Bool { player?.isPlaying ?? false }

    // One second of silence as a WAV file (mono, 8 kHz, 16-bit), built in memory.
    private static func silentWav() -> Data {
        let rate: UInt32 = 8000
        let samples = Int(rate)
        let dataSize = UInt32(samples * 2)
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        d.append(Data(count: samples * 2))
        return d
    }
}
