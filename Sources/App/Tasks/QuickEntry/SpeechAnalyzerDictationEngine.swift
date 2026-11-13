import AVFoundation
import CoreState
import Foundation
import os
import Speech

/// Dictation with Apple's speech recognition on this Mac. The audio goes
/// from the microphone to `SpeechAnalyzer` and nowhere else: Toastty keeps
/// no recording, and the transcriber modules send no audio to Apple.
@available(macOS 26.0, *)
@MainActor
final class SpeechAnalyzerDictationEngine: QuickEntryDictationEngine {
    private let openAudio: DictationAudioOpener
    private var session: Session?

    /// `openAudio` turns the audio on: the microphone, after macOS allowed
    /// it. A check of the engine without a microphone passes a file's audio.
    init(openAudio: @escaping DictationAudioOpener = { try await MicrophoneCapture.open(isStillWanted: $0) }) {
        self.openAudio = openAudio
    }

    func start(onEvent: @escaping @MainActor (QuickEntryDictationEvent) -> Void) {
        cancel()
        let session = Session(openAudio: openAudio, onEvent: onEvent)
        self.session = session
        session.start()
    }

    func stop() {
        session?.stop()
    }

    func cancel() {
        session?.cancel()
        session = nil
    }
}

private struct DictationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A value that crosses to another thread once and is used only there.
struct Transferred<Value>: @unchecked Sendable {
    let value: Value
}

/// Where a session's audio comes from.
@MainActor
protocol DictationAudioSource: AnyObject {
    /// The audio as it was captured. The stream ends when the source stops.
    var buffers: AsyncStream<Transferred<AVAudioPCMBuffer>> { get }
    /// Called with the reason when the source lost its audio for good. The
    /// source has stopped by then.
    var onFailure: (@MainActor (String) -> Void)? { get set }
    func stop()
}

/// Turns a session's audio on. It can take a while, when macOS asks the
/// user for the microphone first. `isStillWanted` says whether the session
/// still wants the audio then; when not, the opener turns nothing on and
/// returns `nil`.
typealias DictationAudioOpener = @MainActor (_ isStillWanted: @MainActor () -> Bool) async throws -> (any DictationAudioSource)?

/// One run from the key press to the last word.
@available(macOS 26.0, *)
@MainActor
private final class Session {
    private let openAudio: DictationAudioOpener
    private let onEvent: @MainActor (QuickEntryDictationEvent) -> Void
    private var task: Task<Void, Never>?
    private var microphone: (any DictationAudioSource)?
    private var analyzer: SpeechAnalyzer?
    /// How many audio buffers went to the analyzer.
    private let deliveredBuffers = OSAllocatedUnfairLock(initialState: 0)
    /// `stop()` came: the microphone is off, or must not go on.
    private var stopRequested = false
    private var finishStarted = false
    /// Set by `cancel()`, and after `.ended`: nothing more is reported.
    private var isOver = false

    init(
        openAudio: @escaping DictationAudioOpener,
        onEvent: @escaping @MainActor (QuickEntryDictationEvent) -> Void
    ) {
        self.openAudio = openAudio
        self.onEvent = onEvent
    }

    func start() {
        task = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() {
        guard isOver == false, stopRequested == false else { return }
        stopRequested = true
        microphone?.stop()
        finishIfStarted()
    }

    func cancel() {
        guard isOver == false else { return }
        isOver = true
        task?.cancel()
        microphone?.stop()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    private func emit(_ event: QuickEntryDictationEvent) {
        guard isOver == false else { return }
        if case .ended = event { isOver = true }
        onEvent(event)
    }

    private func run() async {
        do {
            // The microphone goes on before the speech model loads, so the
            // first words are not lost: the audio waits for the analyzer.
            // `stop()` or `cancel()` can come while macOS asks for access.
            // Then the microphone must not go on, and there is nothing to
            // hear.
            let isStillWanted: @MainActor () -> Bool = { [weak self] in
                self.map { $0.stopRequested == false && $0.isOver == false } ?? false
            }
            guard let microphone = try await openAudio(isStillWanted), isStillWanted() else {
                microphone?.stop()
                emit(.ended(error: nil))
                return
            }
            self.microphone = microphone
            microphone.onFailure = { [weak self] reason in
                self?.fail(reason)
            }
            emit(.listening)

            let transcriber = try await Transcriber.make(for: .current)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber.module]) {
                emit(.downloadingModel)
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber.module]) else {
                throw DictationError("Dictation found no audio format that the speech model takes.")
            }
            let analyzer = SpeechAnalyzer(
                modules: [transcriber.module],
                // The model stays loaded for a while, so the next panel
                // starts faster.
                options: .init(priority: .userInitiated, modelRetention: .lingering)
            )
            try Task.checkCancellation()
            self.analyzer = analyzer
            try await analyzer.start(
                inputSequence: analyzerInput(from: microphone.buffers, in: format, counting: deliveredBuffers)
            )
            ToasttyLog.info("Started quick entry dictation", category: .tasks, metadata: [
                "transcriber": transcriber.name,
                "locale": transcriber.locale.identifier,
            ])
            finishIfStarted()
            try await transcriber.forEachResult { [weak self] words, isFinal in
                self?.emit(isFinal ? .final(words) : .volatile(words))
            }
            microphone.stop()
            emit(.ended(error: nil))
        } catch {
            microphone?.stop()
            guard isOver == false else { return }
            if let analyzer {
                Task { await analyzer.cancelAndFinishNow() }
            }
            ToasttyLog.warning("Quick entry dictation ended with an error", category: .tasks, metadata: [
                "error": String(describing: error),
            ])
            emit(.ended(error: error.localizedDescription))
        }
    }

    /// The audio is gone for good: ends the session with the reason.
    private func fail(_ reason: String) {
        guard isOver == false else { return }
        microphone?.stop()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
        emit(.ended(error: reason))
        task?.cancel()
    }

    /// After `stop()`: has the analyzer work through the audio it has, which
    /// ends the results.
    private func finishIfStarted() {
        guard stopRequested, finishStarted == false, let analyzer else { return }
        finishStarted = true
        Task { [weak self] in
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                // The analyzer ends its results only after it had audio.
                // `stop()` can come before the microphone's first buffer.
                guard let self, deliveredBuffers.withLock({ $0 }) == 0 else { return }
                await analyzer.cancelAndFinishNow()
                emit(.ended(error: nil))
                task?.cancel()
            } catch {
                await analyzer.cancelAndFinishNow()
                self?.emit(.ended(error: error.localizedDescription))
            }
        }
    }
}

/// The speech module in use. `SpeechTranscriber` is the more exact one; a
/// Mac or a language without it gets the model of the system's dictation.
@available(macOS 26.0, *)
private enum Transcriber {
    case speech(SpeechTranscriber, Locale)
    case dictation(DictationTranscriber, Locale)

    static func make(for locale: Locale) async throws -> Transcriber {
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            return .speech(
                SpeechTranscriber(
                    locale: supported,
                    transcriptionOptions: [],
                    // Fast results: the words in progress come about once a
                    // second, not once every four.
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: []
                ),
                supported
            )
        }
        if let supported = await DictationTranscriber.supportedLocale(equivalentTo: locale) {
            return .dictation(
                DictationTranscriber(
                    locale: supported,
                    contentHints: [],
                    transcriptionOptions: [.punctuation],
                    reportingOptions: [.volatileResults, .frequentFinalization],
                    attributeOptions: []
                ),
                supported
            )
        }
        let language = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        throw DictationError("Dictation on this Mac does not support \(language).")
    }

    var module: any SpeechModule {
        switch self {
        case .speech(let transcriber, _): transcriber
        case .dictation(let transcriber, _): transcriber
        }
    }

    var name: String {
        switch self {
        case .speech: "speech"
        case .dictation: "dictation"
        }
    }

    var locale: Locale {
        switch self {
        case .speech(_, let locale), .dictation(_, let locale): locale
        }
    }

    /// Calls `body` with each result's words, and whether they are final,
    /// until the analyzer finishes.
    @MainActor
    func forEachResult(_ body: @MainActor (String, Bool) -> Void) async throws {
        switch self {
        case .speech(let transcriber, _):
            for try await result in transcriber.results {
                body(String(result.text.characters), result.isFinal)
            }
        case .dictation(let transcriber, _):
            for try await result in transcriber.results {
                body(String(result.text.characters), result.isFinal)
            }
        }
    }
}

/// The microphone, as a stream of audio buffers. Each buffer is a copy:
/// the audio engine uses its own buffer again after the tap returns.
@MainActor
final class MicrophoneCapture: DictationAudioSource {
    private let engine = AVAudioEngine()
    let buffers: AsyncStream<Transferred<AVAudioPCMBuffer>>
    private let continuation: AsyncStream<Transferred<AVAudioPCMBuffer>>.Continuation
    // Removed in deinit, which is not main-actor isolated.
    nonisolated(unsafe) private var configurationObserver: (any NSObjectProtocol)?
    private var isStopped = false
    var onFailure: (@MainActor (String) -> Void)?

    /// Asks macOS for the microphone the first time, then turns it on,
    /// unless the session ended while macOS asked.
    static func open(isStillWanted: @MainActor () -> Bool) async throws -> MicrophoneCapture? {
        // Before the question: macOS would ask for a microphone that the
        // Mac does not have.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw DictationError("Toastty found no microphone.")
        }
        let denied = DictationError(
            "Toastty has no access to the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
        )
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw denied }
        default:
            throw denied
        }
        guard isStillWanted() else { return nil }
        return try MicrophoneCapture()
    }

    private init() throws {
        (buffers, continuation) = AsyncStream.makeStream()
        try startEngine()
        // A change of the input device, such as headphones that connect,
        // stops the engine. Start it again on the new device.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restartAfterConfigurationChange()
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    func stop() {
        guard isStopped == false else { return }
        isStopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation.finish()
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A Mac without an input device reports an empty format, and a tap
        // with that format raises an exception.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw DictationError("Toastty found no microphone.")
        }
        Self.installTap(on: input, format: format, into: continuation)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DictationError("The microphone did not start: \(error.localizedDescription)")
        }
    }

    private func restartAfterConfigurationChange() {
        guard isStopped == false else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try startEngine()
        } catch {
            ToasttyLog.warning("Quick entry dictation lost the microphone", category: .tasks, metadata: [
                "error": error.localizedDescription,
            ])
            stop()
            onFailure?("Dictation lost the microphone. \(error.localizedDescription)")
        }
    }

    /// Not main-actor isolated, so that the tap, which the audio engine
    /// calls on its own thread, is not either.
    nonisolated private static func installTap(
        on input: AVAudioInputNode,
        format: AVAudioFormat,
        into continuation: AsyncStream<Transferred<AVAudioPCMBuffer>>.Continuation
    ) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let copy = buffer.copied() else { return }
            continuation.yield(Transferred(value: copy))
        }
    }
}

/// The captured audio in the analyzer's format. The stream ends when the
/// source stops.
@available(macOS 26.0, *)
private func analyzerInput(
    from buffers: AsyncStream<Transferred<AVAudioPCMBuffer>>,
    in format: AVAudioFormat,
    counting delivered: OSAllocatedUnfairLock<Int>
) -> AsyncStream<AnalyzerInput> {
    let (stream, output) = AsyncStream<AnalyzerInput>.makeStream()
    let target = Transferred(value: format)
    Task.detached(priority: .userInitiated) {
        // The input format changes when the input device does.
        var converter: AVAudioConverter?
        for await captured in buffers {
            let buffer = captured.value
            var input: AVAudioPCMBuffer? = buffer
            if buffer.format != target.value {
                if converter?.inputFormat != buffer.format {
                    converter = AVAudioConverter(from: buffer.format, to: target.value)
                }
                input = converter?.converted(buffer)
            }
            if let input {
                delivered.withLock { $0 += 1 }
                output.yield(AnalyzerInput(buffer: input))
            }
        }
        output.finish()
    }
    return stream
}

private extension AVAudioPCMBuffer {
    func copied() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}

private extension AVAudioConverter {
    /// One buffer in the output format. The converter keeps what it needs
    /// between buffers, so the audio stays continuous.
    func converted(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        let input = Transferred(value: buffer)
        let provided = Provided()
        var error: NSError?
        let status = convert(to: output, error: &error) { _, inputStatus in
            if provided.value {
                inputStatus.pointee = .noDataNow
                return nil
            }
            provided.value = true
            inputStatus.pointee = .haveData
            return input.value
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// Whether the one input buffer was handed to the converter.
    private final class Provided: @unchecked Sendable {
        var value = false
    }
}
