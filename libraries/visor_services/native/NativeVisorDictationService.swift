// Dictation from the system's speech recognizer (the Speech framework),
// fed by the microphone through an audio engine tap. On a phone the
// audio session is taken for recording while listening and given back
// after; a Mac has no session. (A TV and a watch have no recognizer: the
// build leaves this file out there.)

import AVFoundation
import Speech

@MainActor
public final class NativeVisorDictationService: VisorDictationService {
    /// One listening: the engine whose tap feeds the request the
    /// recognizer reads; made and taken apart as one.
    private struct Listening {
        let engine: AVAudioEngine
        let request: SFSpeechAudioBufferRecognitionRequest
        let task: SFSpeechRecognitionTask
    }

    private var listening: Listening?

    public init() {}

    public func start(heard: @escaping @MainActor @Sendable (String) -> Void) async throws {
        stop()
        guard await Self.speechAuthorized() else { throw VisorDictationRefused("Speech recognition is not allowed for Visor.") }
        guard await Self.microphoneAuthorized() else { throw VisorDictationRefused("The microphone is not allowed for Visor.") }
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        listening = try Self.begin(heard: heard)
    }

    /// The engine, request and recognition started. Outside the main
    /// actor: the tap is called on the audio thread and the recognizer's
    /// results on its own queue, so neither callback is built on it.
    nonisolated private static func begin(heard: @escaping @MainActor @Sendable (String) -> Void) throws -> Listening {
        guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
            throw VisorDictationRefused("Speech recognition is not available.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        let engine = AVAudioEngine()
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()
        let task = recognizer.recognitionTask(with: request) { result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in heard(text) }
        }
        return Listening(engine: engine, request: request, task: task)
    }

    public func stop() {
        guard let ended = listening else { return }
        listening = nil
        ended.engine.inputNode.removeTap(onBus: 0)
        ended.engine.stop()
        ended.request.endAudio()
        ended.task.finish()
        #if !os(macOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
