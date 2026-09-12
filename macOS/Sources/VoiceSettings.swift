import Foundation
import Observation
import AVFoundation

/// Settings instances are inert until explicit preparation or the shared production startup task.
@MainActor @Observable
final class VoicePreparation {
    enum Action { case authorize, openSettings, retry }
    let service: any VoiceRecognitionServing
    private(set) var preparing = false
    private(set) var action: Action?
    private(set) var message: String

    init(service: any VoiceRecognitionServing = AppleVoiceRecognizer()) {
        self.service = service
        action = service.isReady ? nil : .authorize
        message = service.isReady ? "中文语音识别已就绪。" : "允许使用麦克风后，将自动准备中文识别资源。"
    }

    func prepareIfAuthorized(status: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }) async {
        guard !preparing else { return }
        switch status() {
        case .notDetermined:
            action = .authorize
            message = "允许使用麦克风后，将自动准备中文识别资源。"
        case .authorized:
            if service.isReady {
                action = nil
                message = "中文语音识别已就绪。"
            } else if action != .retry {
                await prepare(requestPermission: false)
            }
        default:
            action = .openSettings
            message = "请在系统设置中允许墨流使用麦克风。"
        }
    }

    func prepare(requestPermission: Bool = true) async {
        guard !preparing else { return }
        preparing = true
        action = nil
        message = "正在准备中文识别资源…"
        defer { preparing = false }
        do {
            try await service.prepare(requestPermission: requestPermission)
            action = service.isReady ? nil : .retry
            message = service.isReady ? "中文语音识别已就绪。" : "语音识别尚未就绪，请重试。"
        } catch {
            let denied = error as? VoiceRecognitionError == .permission
            action = denied ? .openSettings : .retry
            message = denied ? "请在系统设置中允许墨流使用麦克风。" : "无法准备中文语音识别，请检查网络和系统资源后重试。"
        }
    }
}
