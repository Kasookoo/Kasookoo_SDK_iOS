import Foundation
import AVFoundation

public protocol KasookooSDKDelegate: AnyObject {
    func kasookooCallDidStart()
    func kasookooCallDidConnect()
    func kasookooCallDidEnd()
    func kasookooCallDidFail(error: Error)
}

public final class KasookooSDK {
    public static let shared = KasookooSDK()
    public weak var delegate: KasookooSDKDelegate?
    private var apiClient = ApiClient()
    private var liveKit = LiveKitManager()
    private var audioManager = CallAudioManager()
    private var baseURL: String = ""
    private var activeCall: CallSession?

    private init() {}

    public func configure(apiBaseURL: String) {
        baseURL = apiBaseURL
        apiClient.configure(baseURL: apiBaseURL)
    }

    public var isCallActive: Bool {
        activeCall != nil
    }

    public func startCall(to userId: String) {
        delegate?.kasookooCallDidStart()
        apiClient.getCallerToken(for: userId) { [weak self] token in
            guard let self = self, let token else {
                self?.delegate?.kasookooCallDidFail(error: NSError(domain: "TokenError", code: 0))
                return
            }
            self.activeCall = CallSession(remoteUserId: userId, token: token)
            self.liveKit.connect(with: token) { success in
                if success {
                    self.audioManager.setupAudioSession()
                    self.delegate?.kasookooCallDidConnect()
                } else {
                    self.delegate?.kasookooCallDidFail(error: NSError(domain: "ConnectionError", code: 0))
                }
            }
        }
    }

    public func endCall() {
        guard activeCall != nil else { return }
        liveKit.disconnect()
        audioManager.stopAudioSession()
        activeCall = nil
        delegate?.kasookooCallDidEnd()
    }

    public func toggleSpeaker() {
        audioManager.toggleSpeaker()
    }
}
