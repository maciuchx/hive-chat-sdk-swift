import Foundation
import AVFoundation

/// Records a voice note as AAC-in-MP4.
///
/// `m4a` is chosen over the alternatives because it is the one recording
/// format that survives every leg of the journey: the agent dashboard plays it
/// in an `<audio>` element, and it is on the narrow list of media WhatsApp
/// accepts, so a chat that later moves to WhatsApp does not fail with a 63021.
///
/// An observable object rather than a value type: recording outlives a view
/// update, and a recorder released mid-recording holds the microphone.
@MainActor
final class VoiceRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedSeconds = 0

    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var timer: Timer?

    /// Asks for the microphone, then starts. The prompt appears the first time
    /// the customer taps record — never at launch.
    func start() async throws {
        guard await requestPermission() else { throw VoiceRecorderError.microphoneDenied }

        #if os(iOS) || os(visionOS)
        /* Ducking rather than interrupting: a customer recording a voice note
           while music plays should not have it stopped dead. */
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true)
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hive-voice-\(UUID().uuidString).m4a")

        /* Speech, not music. 32 kbps mono keeps a minute under a quarter of a
           megabyte, which matters on a phone uploading over cellular against a
           5 MB cap. */
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ])
        recorder.record()

        self.recorder = recorder
        self.fileURL = url
        isRecording = true
        elapsedSeconds = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.elapsedSeconds += 1 }
        }
        self.timer = timer
    }

    /// Stops and returns the recording, or nil if it was too short to be
    /// anything but a mis-tap.
    func stopAndTake() -> (data: Data, filename: String)? {
        recorder?.stop()
        cleanUp()

        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        fileURL = nil

        /* An MP4 header alone is a few hundred bytes, so anything at this size
           carries no audio — a tap that never became a recording. */
        guard data.count > 1_200 else { return nil }
        return (data, "voice-message.m4a")
    }

    /// Abandons the recording and deletes the file.
    func cancel() {
        recorder?.stop()
        cleanUp()
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
    }

    private func cleanUp() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        isRecording = false
        #if os(iOS) || os(visionOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func requestPermission() async -> Bool {
        #if os(iOS) || os(visionOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        /* macOS gates the microphone through the sandbox entitlement rather
           than a runtime prompt, so there is nothing to ask for here. */
        return true
        #endif
    }
}

enum VoiceRecorderError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        "Microphone access is needed to record a voice message."
    }
}
