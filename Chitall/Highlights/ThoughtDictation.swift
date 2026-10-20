import AVFoundation
import Observation
import Speech
import SwiftUI

/// "Мысль голосом" (DECISIONS.md §20): speech to text for the thought of a highlight.
/// `SFSpeechRecognizer` for Russian, only on the device (`requiresOnDeviceRecognition`):
/// no server, no key, the voice does not leave the iPhone. Where the iPhone cannot recognise
/// Russian offline, the editor says so and points to the keyboard's own dictation.
@MainActor
@Observable
final class ThoughtDictation {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case unavailable(String)
    }

    static let locale = Locale(identifier: "ru-RU")

    private(set) var state: State = .idle
    /// Receives the whole thought: what was written before plus what has been said so far.
    @ObservationIgnored var onText: (String) -> Void = { _ in }

    @ObservationIgnored private var base = ""
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    /// The current dictation: late results of an earlier one are ignored.
    @ObservationIgnored private var session = UUID()

    var isListening: Bool { state == .listening || state == .starting }

    /// Why dictation cannot work here, or `nil` when it can (before asking for permissions).
    static func unavailableReason(_ recognizer: SFSpeechRecognizer?) -> String? {
        guard let recognizer else {
            return "Распознавание русской речи на этом iPhone недоступно. Надиктовать мысль можно микрофоном на клавиатуре."
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return "Этот iPhone не распознаёт русскую речь без интернета, а Chitall не отправляет голос на серверы. Надиктовать мысль можно микрофоном на клавиатуре (системная диктовка)."
        }
        guard recognizer.isAvailable else {
            return "Распознавание речи сейчас недоступно. Попробуйте чуть позже или микрофон на клавиатуре."
        }
        return nil
    }

    func toggle(note: String) {
        if isListening {
            stop()
        } else {
            Task { await start(note: note) }
        }
    }

    func start(note: String) async {
        guard !isListening else { return }
        let recognizer = SFSpeechRecognizer(locale: Self.locale)
        if let reason = Self.unavailableReason(recognizer) {
            state = .unavailable(reason)
            return
        }
        guard let recognizer else { return }
        state = .starting

        let speech = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speech == .authorized else {
            state = .unavailable("Нет разрешения на распознавание речи. Его можно дать в Настройках → Chitall.")
            return
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            state = .unavailable("Нет доступа к микрофону. Его можно дать в Настройках → Chitall.")
            return
        }
        guard state == .starting else { return } // stopped while the permission dialogs were open

        do {
            begin(with: note)
            try listen(with: recognizer)
            state = .listening
        } catch {
            finish()
            state = .unavailable("Не удалось включить микрофон: \(error.localizedDescription)")
        }
    }

    private func listen(with recognizer: SFSpeechRecognizer) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(feeding: request))
        engine.prepare()
        try engine.start()
        session = UUID()
        task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(for: self, session: session))
    }

    // The audio tap and the recognizer call back on their own threads: their closures are
    // made outside the main actor, so they are not tied to it, and hop back to it themselves.

    nonisolated private static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { buffer, _ in request.append(buffer) }
    }

    nonisolated private static func resultHandler(for dictation: ThoughtDictation, session: UUID) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak dictation] result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let dictation, dictation.session == session else { return }
                if let text { dictation.receive(text) }
                if done { dictation.finish() }
            }
        }
    }

    /// The thought as it was when dictation started: what is said is added to it.
    func begin(with note: String) {
        base = note
    }

    /// A new (growing) transcript of what has been said since `begin`.
    func receive(_ transcript: String) {
        onText(DictationText.merge(base, transcript))
    }

    /// Stops listening; the last words still arrive as the final result.
    func stop() {
        guard isListening else { return }
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        if task == nil { finish() }
        state = .idle
    }

    /// Everything off and the audio session back to the other apps.
    func finish() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if state == .listening || state == .starting { state = .idle }
    }
}

/// The microphone button above the thought field, and what it is doing.
struct DictationButton: View {
    let dictation: ThoughtDictation
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                dictation.toggle(note: note)
            } label: {
                Label(
                    dictation.isListening ? "Остановить" : "Надиктовать",
                    systemImage: dictation.isListening ? "stop.circle.fill" : "mic"
                )
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(dictation.isListening ? Palette.background : Palette.accent)
                .background(dictation.isListening ? Palette.accent : Palette.surface, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Мысль голосом, распознаётся на iPhone без интернета")
            switch dictation.state {
            case .listening:
                Text("Слушаю — говорите. Слова добавляются к мысли.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            case .starting:
                Text("Включаю микрофон…")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            case let .unavailable(reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
        }
    }
}
