import AVFoundation
import CoreMedia
import Foundation
import Speech
#if SWIFT_PACKAGE
@testable import InkFlowCore
#endif

@MainActor
private final class PreparationService: VoiceRecognitionServing {
    var isReady = false
    var requests: [Bool] = []
    var fail = false
    var duringPreparation: (() async -> Void)?
    func prepare(requestPermission: Bool) async throws {
        requests.append(requestPermission)
        await duringPreparation?()
        if fail { throw VoiceRecognitionError.unavailable }
        isReady = true
    }
    func start(id: UUID, snapshot: VoiceLexiconSnapshot, callbacks: AppleVoiceRecognizer.Callbacks) {
        preconditionFailure("Preparation must not start recording")
    }
    func stop(id: UUID) {}
    func cancel() {}
}

@main
struct AppleVoiceRecognizerTests {
    @MainActor static func fixtureLifecycle() async {
        var previews: [String] = [], finals: [String] = [], finalized: [String] = []
        let callbacks = AppleVoiceRecognizer.Callbacks(onFinal: { finals.append($0) },
            onVolatile: { previews.append($0) }, onFinalized: { finalized.append($0) },
            onFailure: { preconditionFailure("Fixture cannot fail recognition") })
        let final = VoiceRecognitionFixture(mode: .final)
        let id = UUID()
        final.start(id: id, snapshot: .unknown(), callbacks: callbacks)
        final.stop(id: id); final.stop(id: id)
        precondition(previews.isEmpty && finals.isEmpty && finalized == ["语音测试"],
                     "Final fixture never invokes the preview-producing segment callback")
        finalized = []
        var sleeps: [Duration] = []
        let preview = VoiceRecognitionFixture(mode: .preview, sleep: {
            sleeps.append($0); await Task.yield()
        })
        preview.start(id: id, snapshot: .unknown(), callbacks: callbacks)
        for _ in 0..<30 { await Task.yield() }
        precondition(previews == ["语音测", "语音测试"] && sleeps == [.seconds(1), .seconds(1)])
        preview.stop(id: id); preview.stop(id: id)
        precondition(finals == ["语音测试"] && finalized == ["语音测试"])
        previews = []; finals = []; finalized = []
        preview.start(id: UUID(), snapshot: .unknown(), callbacks: callbacks)
        preview.cancel()
        for _ in 0..<30 { await Task.yield() }
        precondition(previews.isEmpty && finals.isEmpty && finalized.isEmpty, "Cancellation suppresses late callbacks")
        let reentrant = AppleVoiceRecognizer.Callbacks(onFinal: { _ in preview.cancel() },
            onVolatile: { _ in }, onFinalized: { _ in preconditionFailure("Cancelled finalization arrived") }, onFailure: {})
        preview.start(id: id, snapshot: .unknown(), callbacks: reentrant)
        preview.stop(id: id)
    }

    @MainActor static func automaticPreparation() async {
        var prompts = 0
        for status: AVAuthorizationStatus in [.notDetermined, .denied, .restricted, .authorized] {
            let allowed = await AppleVoiceRecognizer.microphoneAllowed(requestPermission: false,
                status: { status }, request: { prompts += 1; return true })
            precondition(allowed == (status == .authorized) && prompts == 0)
        }
        let allowed = await AppleVoiceRecognizer.microphoneAllowed(requestPermission: true,
            status: { .notDetermined }, request: { prompts += 1; return true })
        precondition(allowed && prompts == 1)

        let service = PreparationService()
        let model = VoicePreparation(service: service)
        precondition(model.action == .authorize)
        precondition(service.requests.isEmpty, "Constructing settings preparation remains inert")
        for status: AVAuthorizationStatus in [.notDetermined, .denied, .restricted] {
            await model.prepareIfAuthorized(status: { status })
            precondition(model.action == (status == .notDetermined ? .authorize : .openSettings))
        }
        precondition(service.requests.isEmpty && !model.preparing)
        service.duringPreparation = { precondition(model.preparing && model.action == nil); await model.prepare() }
        await model.prepareIfAuthorized(status: { .authorized })
        precondition(service.requests == [false] && service.isReady && !model.preparing,
                     "Automatic and explicit preparation share the in-flight guard")
        await model.prepareIfAuthorized(status: { .authorized })
        precondition(model.action == nil)
        precondition(service.requests == [false], "Ready resources are not prepared twice")
        service.duringPreparation = nil

        let retry = PreparationService()
        let retryModel = VoicePreparation(service: retry)
        retry.fail = true
        await retryModel.prepareIfAuthorized(status: { .authorized })
        precondition(!retry.isReady && !retryModel.preparing)
        precondition(retryModel.action == .retry)
        await retryModel.prepareIfAuthorized(status: { .authorized })
        precondition(retry.requests == [false], "Failed preparation waits for explicit retry")
        retry.fail = false
        await retryModel.prepare()
        precondition(retry.requests == [false, true] && retry.isReady, "Failure retains the explicit retry route")
    }

    static func range(_ start: Int64, _ duration: Int64 = 1) -> CMTimeRange {
        CMTimeRange(start: CMTime(value: start, timescale: 1), duration: CMTime(value: duration, timescale: 1))
    }
    @MainActor static func main() async throws {
        await automaticPreparation()
        await fixtureLifecycle()
        // Invoke the exact production tap on a detached executor, without opening a microphone.
        let input = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let output = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let feed = try VoiceAudioFeed(input: input, output: output)
        let tap = feed.makeTap()
        await Task.detached {
            precondition(!Thread.isMainThread)
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48000))
        }.value
        feed.finish()
        var frameCount = 0
        for try await sample in feed.stream {
            precondition(sample.buffer.format.sampleRate == 16000)
            frameCount += Int(sample.buffer.frameLength)
        }
        precondition(frameCount == 1600, "Converted frame count: \(frameCount)")

        let overflowing = try VoiceAudioFeed(input: input, output: output, capacity: 1)
        let overflowTap = overflowing.makeTap()
        await Task.detached {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
            buffer.frameLength = 4800
            buffer.floatChannelData![0].initialize(repeating: 0, count: 4800)
            for _ in 0..<3 { overflowTap(buffer, AVAudioTime(sampleTime: 0, atRate: 48000)) }
        }.value
        do {
            for try await _ in overflowing.stream {}
            preconditionFailure("Audio overflow must fail")
        } catch { precondition(error is VoiceRecognitionError) }

        var transcript = VoiceTranscriptAccumulator()
        var suffix = try transcript.updateVolatile("wrong", range: range(0))
        precondition(suffix == "wrong")
        suffix = try transcript.updateVolatile("right", range: range(0))
        precondition(suffix == "right")
        try transcript.appendFinal("张", range: range(0))
        suffix = try transcript.updateVolatile("伟", range: range(1))
        precondition(suffix == "伟" && transcript.transcript == "张")
        try transcript.appendFinal("玮", range: range(1))
        precondition(transcript.transcript == "张玮")
        _ = try transcript.updateVolatile("撤回", range: range(2))
        try transcript.appendFinal("", range: range(2))
        precondition(transcript.volatileSuffix.isEmpty && transcript.transcript == "张玮", "Empty final revokes obsolete volatile preview")
        do { try transcript.appendFinal("duplicate", range: range(1)); preconditionFailure("Accepted overlapping final") }
        catch { precondition(error is VoiceRecognitionError) }

        // Immediate key release/cancel cannot open the microphone or prepare language assets.
        let service = AppleVoiceRecognizer(preparation: .init(locale: Locale(identifier: "zh_CN")))
        var finals: [String] = [], failures = 0
        let callbacks = AppleVoiceRecognizer.Callbacks(onFinal: { _ in preconditionFailure("Unexpected final") },
            onVolatile: { _ in preconditionFailure("Unexpected preview") },
            onFinalized: { finals.append($0) }, onFailure: { failures += 1 })
        let token = UUID()
        service.start(id: token, snapshot: .unknown(), callbacks: callbacks)
        service.stop(id: token)
        for _ in 0..<10 { await Task.yield() }
        precondition(finals == [""] && failures == 0)
        service.start(id: UUID(), snapshot: .unknown(), callbacks: callbacks)
        service.cancel()
        for _ in 0..<10 { await Task.yield() }
        precondition(finals == [""] && failures == 0)
        let unprepared = AppleVoiceRecognizer()
        precondition(!unprepared.isReady)
        unprepared.start(id: UUID(), snapshot: .unknown(), callbacks: callbacks)
        for _ in 0..<10 { await Task.yield() }
        precondition(failures == 1)
        print("Apple voice synthetic audio and lifecycle tests passed")
    }
}
