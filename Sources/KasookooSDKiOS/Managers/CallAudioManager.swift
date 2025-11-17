import AVFoundation

final class CallAudioManager {
    private var isSpeakerOn = false

    func setupAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func stopAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    func toggleSpeaker() {
        isSpeakerOn.toggle()
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
    }
}
