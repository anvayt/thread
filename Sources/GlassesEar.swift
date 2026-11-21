import AVFoundation
import Combine
import Foundation
import Speech

/// Counts how much audio has arrived, from whichever thread delivers it.
final class AudioTally: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Double = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        lock.lock()
        total += Double(buffer.frameLength) / rate
        lock.unlock()
    }

    func reset() {
        lock.lock()
        total = 0
        lock.unlock()
    }

    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return total
    }
}

/// Measures and keeps one turn of the glasses' audio, from the SDK's thread:
/// its format, its level each second, how much of it reached the recogniser,
/// and a mono copy that can be transcribed again once the turn is over.
///
/// The copy exists because the live transcription of this audio has come
/// back empty on real glasses while audio was arriving. Transcribing the
/// copy afterwards, with no other recogniser running, tells apart audio that
/// is broken from a recogniser that was stopped, and recovers the words in
/// the second case.
final class AudioProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var began = Date()
    private var samples: [Float] = []
    private var sampleRate: Double = 0
    private var formatLine = ""
    private var appended = 0
    private var dropped = 0
    private var peak: Float = 0
    private var badValues = 0
    private var zeros = 0
    private var counted = 0
    private var lastFrameAt: Double?
    private var maxGap: Double = 0
    private var secondStart: Double = 0
    private var secondSquares: Double = 0
    private var secondCount = 0
    private var levels: [Int] = []

    /// A turn never keeps more than this much audio.
    private static let maxSeconds = 180.0

    func start() {
        lock.lock()
        defer { lock.unlock() }
        active = true
        began = Date()
        samples.removeAll(keepingCapacity: true)
        sampleRate = 0
        formatLine = ""
        appended = 0
        dropped = 0
        peak = 0
        badValues = 0
        zeros = 0
        counted = 0
        lastFrameAt = nil
        maxGap = 0
        secondStart = 0
        secondSquares = 0
        secondCount = 0
        levels = []
    }

    func stop() {
        lock.lock()
        active = false
        lock.unlock()
    }

    /// Called for every frame, inside the SDK's callback, so the samples are
    /// copied out before the buffer can be reused.
    func record(_ buffer: AVAudioPCMBuffer, accepted: Bool) {
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        var mono = [Float](repeating: 0, count: frames)
        if let channels = buffer.floatChannelData {
            let first = channels[0]
            for i in 0..<frames { mono[i] = first[i * stride] }
        } else if let channels = buffer.int16ChannelData {
            let first = channels[0]
            for i in 0..<frames { mono[i] = Float(first[i * stride]) / 32768 }
        } else if let channels = buffer.int32ChannelData {
            let first = channels[0]
            for i in 0..<frames { mono[i] = Float(first[i * stride]) / 2_147_483_648 }
        }

        lock.lock()
        defer { lock.unlock() }
        guard active else { return }
        let now = Date().timeIntervalSince(began)
        let format = buffer.format
        if formatLine.isEmpty {
            sampleRate = format.sampleRate
            secondStart = now
            formatLine = String(
                format: "%@ %.0f Hz, %u channel(s), interleaved %@, %d frames, stride %d, first frame +%.2fs",
                Self.name(of: format.commonFormat), format.sampleRate, format.channelCount,
                format.isInterleaved ? "yes" : "no", frames, stride, now
            )
        }
        if let last = lastFrameAt { maxGap = max(maxGap, now - last) }
        lastFrameAt = now
        if accepted { appended += 1 } else { dropped += 1 }

        for value in mono {
            guard value.isFinite else {
                badValues += 1
                continue
            }
            let size = abs(value)
            if size > peak { peak = size }
            if value == 0 { zeros += 1 }
            counted += 1
            secondSquares += Double(value * value)
            secondCount += 1
        }
        if sampleRate > 0, Double(samples.count) < Self.maxSeconds * sampleRate {
            samples.append(contentsOf: mono)
        }
        if now - secondStart >= 1 {
            let rms = secondCount > 0 ? (secondSquares / Double(secondCount)).squareRoot() : 0
            levels.append(rms > 0 ? Int((20 * log10(rms)).rounded()) : -160)
            secondStart = now
            secondSquares = 0
            secondCount = 0
        }
    }

    /// One line for the log: what arrived and what it looked like.
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        guard !formatLine.isEmpty else { return "no frames arrived" }
        let zeroShare = counted > 0 ? Double(zeros) / Double(counted) * 100 : 0
        return String(
            format: "%@; frames appended %d, dropped %d; peak %.4f; non-finite %d; zeros %.0f%%; max gap %.2fs; level dBFS per second [%@]",
            formatLine, appended, dropped, peak, badValues, zeroShare, maxGap,
            levels.map(String.init).joined(separator: " ")
        )
    }

    /// Seconds of audio kept.
    var seconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// Writes the kept audio as a 16-bit mono WAV file.
    func writeWAV(to url: URL) throws {
        lock.lock()
        let copy = samples
        let rate = sampleRate
        lock.unlock()
        guard rate > 0, !copy.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(copy.count)),
              let channel = buffer.floatChannelData?[0]
        else { throw CocoaError(.fileWriteUnknown) }
        for (i, value) in copy.enumerated() {
            channel[i] = value.isFinite ? max(-1, min(1, value)) : 0
        }
        buffer.frameLength = AVAudioFrameCount(copy.count)
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private static func name(of format: AVAudioCommonFormat) -> String {
        switch format {
        case .pcmFormatFloat32: return "Float32"
        case .pcmFormatFloat64: return "Float64"
        case .pcmFormatInt16: return "Int16"
        case .pcmFormatInt32: return "Int32"
        default: return "other"
        }
    }
}

/// Transcribes what the glasses' microphones hear during a Meet turn, next to
/// the phone's own microphone.
///
/// The audio never touches the iPhone's audio route. The glasses send it with
/// the camera stream, and `GlassesManager` hands each frame to `sink`. That is
/// what lets both microphones run at once: iOS itself records from one input
/// at a time.
///
/// This is a second opinion and never something a turn depends on. If the
/// glasses send nothing, or a second recogniser will not start, `end()`
/// returns an empty string and the phone's transcript is used as before.
@MainActor
final class GlassesEar: ObservableObject {
    static let shared = GlassesEar()

    /// What the glasses have heard so far this turn.
    @Published private(set) var transcript = ""
    /// What the last turn got from the glasses, in words, for Connect.
    @Published private(set) var lastReport = ""

    /// Where `GlassesManager` puts audio frames, on the SDK's thread.
    let sink = RecognitionSink()
    /// How much audio the glasses have sent since the turn began.
    let tally = AudioTally()
    /// The turn's audio, measured and kept for a second pass.
    let probe = AudioProbe()
    /// When this turn's recogniser started, for timing its errors.
    private var beganAt = Date()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Identifies the task whose results may still change `transcript`.
    private var epoch = 0
    private var settled = false
    private var failure = ""
    private var muteObserver: AnyCancellable?

    private init() {
        // The glasses hear the spoken card as well as the room, so their
        // audio is dropped while it plays, as the phone's is.
        muteObserver = AudioSessionController.shared.$isSpeaking
            .sink { [sink] speaking in sink.setMuted(speaking) }
    }

    /// Start transcribing whatever the glasses send from now on.
    func begin() {
        retire()
        transcript = ""
        settled = false
        failure = ""
        tally.reset()
        probe.start()
        beganAt = Date()

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            failure = "speech recognition is not allowed"
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            failure = "speech recognition is not available"
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = DictationManager.shared.hintNames
        self.request = request
        sink.open(request)

        epoch += 1
        let mine = epoch
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let problem = error?.localizedDescription
            let code = (error as NSError?).map { "\($0.domain) \($0.code)" } ?? ""
            Task { @MainActor in
                guard let self, self.epoch == mine else { return }
                if let problem {
                    print(String(
                        format: "[thread] glasses recogniser error +%.2fs after it began: %@ (%@)",
                        Date().timeIntervalSince(self.beganAt), problem, code
                    ))
                }
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.transcript = text
                }
                if let problem {
                    // Ending a task that heard no speech is reported as an
                    // error too, so this is only worth showing with no text.
                    if self.transcript.isEmpty { self.failure = problem }
                    self.settled = true
                }
                if isFinal { self.settled = true }
            }
        }
    }

    /// Stop, and return what the glasses heard this turn. Empty if nothing.
    func end() async -> String {
        guard request != nil else {
            report(words: 0)
            return ""
        }
        sink.close()
        probe.stop()
        request?.endAudio()
        task?.finish()
        // The recogniser keeps refining for a beat after the audio ends.
        var waited = 0.0
        while !settled, waited < 0.7 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 0.05
        }
        retire()
        print("[thread] glasses audio — \(probe.summary)")

        var text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, probe.seconds >= 1 {
            // The live pass heard nothing although audio arrived. Try the
            // kept copy now that no other recogniser is running.
            let again = await transcribeKeptAudio()
            if !again.isEmpty {
                text = again
                transcript = again
            }
        }
        report(words: Self.wordCount(text))
        return text
    }

    /// Transcribes the turn's kept audio from a file, on the phone. In a debug
    /// build the file is kept as Documents/glasses-last.wav for inspection;
    /// otherwise it is deleted straight after.
    private func transcribeKeptAudio() async -> String {
        guard let recognizer, recognizer.isAvailable else { return "" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glasses-turn.wav")
        do {
            try probe.writeWAV(to: url)
        } catch {
            print("[thread] glasses second pass: could not write the audio (\(error.localizedDescription))")
            return ""
        }
        defer {
            #if DEBUG
            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let kept = documents.appendingPathComponent("glasses-last.wav")
                try? FileManager.default.removeItem(at: kept)
                try? FileManager.default.moveItem(at: url, to: kept)
            }
            #endif
            try? FileManager.default.removeItem(at: url)
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.taskHint = .dictation
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = DictationManager.shared.hintNames
        let started = Date()
        let text: String = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.claim() { continuation.resume(returning: result.bestTranscription.formattedString) }
                } else if let error {
                    print("[thread] glasses second pass error: \(error.localizedDescription)")
                    if once.claim() { continuation.resume(returning: "") }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(8))
                if once.claim() {
                    task.cancel()
                    continuation.resume(returning: "")
                }
            }
        }
        print(String(
            format: "[thread] glasses second pass (%.1fs of audio, %.1fs to transcribe): %d words \"%@\"",
            probe.seconds, Date().timeIntervalSince(started), Self.wordCount(text), text
        ))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// Drop the current task. Nothing it still delivers may change the text.
    private func retire() {
        epoch += 1
        sink.close()
        task?.cancel()
        task = nil
        request = nil
    }

    private func report(words: Int) {
        let seconds = tally.seconds
        if seconds < 0.1 {
            lastReport = "Last capture: no audio arrived from the glasses."
        } else if words == 0, !failure.isEmpty {
            lastReport = String(
                format: "Last capture: %.1f s of audio from the glasses, but no transcript (%@).",
                seconds, failure
            )
        } else {
            lastReport = String(
                format: "Last capture: %.1f s of audio from the glasses, %d words.",
                seconds, words
            )
        }
        print("[thread] glasses ear — \(lastReport) \"\(transcript)\"")
    }
}

/// Lets exactly one of several racing callbacks resume a continuation.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
