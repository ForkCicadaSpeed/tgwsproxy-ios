import Foundation
import AVFoundation
import UIKit
import os.log

private let logger = Logger(subsystem: "com.tgwsproxy.app", category: "BackgroundKeeper")

// BackgroundKeeper keeps the local MTProto proxy alive in the background:
//   1. Silent AVAudioPlayer looping a tiny WAV (UIBackgroundModes = "audio")
//   2. A long UIApplication background task as an extra safety net
//
// Live Activity / Dynamic Island only shows state, it does NOT keep the
// process alive on its own.

@MainActor
@available(iOS 17.0, *)
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var silentPlayer: AVAudioPlayer?
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    private var interruptionObserver: NSObjectProtocol?
    private(set) var isRunning = false

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("BackgroundKeeper start")

        configureAudioSession()
        registerInterruptionObserver()
        startBackgroundTask()
        startSilentAudio()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        logger.info("BackgroundKeeper stop")

        removeInterruptionObserver()
        stopSilentAudio()
        endBackgroundTask()
    }

    func reactivateAudioSession() {
        guard isRunning else { return }
        configureAudioSession()
        if !(silentPlayer?.isPlaying ?? false) {
            logger.info("Audio player was stopped, restarting")
            startSilentAudio()
        }
        startBackgroundTask()
    }

    // MARK: - Audio session configuration

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            logger.warning("Audio session config failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UIApplication background task

    private func startBackgroundTask() {
        endBackgroundTask()
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "TgWsProxyKeepAlive") { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }

    // MARK: - Silent audio (primary keep-alive)

    private func startSilentAudio() {
        let wavData = generateSilentWAV()
        do {
            silentPlayer = try AVAudioPlayer(data: wavData, fileTypeHint: "wav")
            silentPlayer?.numberOfLoops = -1
            silentPlayer?.volume = 0.01
            silentPlayer?.play()
            logger.info("Silent audio player started")
        } catch {
            logger.warning("Silent audio player failed: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        silentPlayer?.stop()
        silentPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private func generateSilentWAV() -> Data {
        let sampleRate: UInt32 = 44100
        let numSamples: UInt32 = sampleRate  // 1 second
        let dataSize = numSamples * 2  // 16-bit mono
        let fileSize = 36 + dataSize

        var wav = Data(capacity: Int(44 + dataSize))

        // RIFF header
        wav.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        withUnsafeBytes(of: fileSize.littleEndian) { wav.append(contentsOf: $0) }
        wav.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        wav.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        withUnsafeBytes(of: UInt32(16).littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) }  // PCM
        withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) }  // mono
        withUnsafeBytes(of: sampleRate.littleEndian) { wav.append(contentsOf: $0) }
        withUnsafeBytes(of: (sampleRate * 2).littleEndian) { wav.append(contentsOf: $0) }  // byte rate
        withUnsafeBytes(of: UInt16(2).littleEndian) { wav.append(contentsOf: $0) }  // block align
        withUnsafeBytes(of: UInt16(16).littleEndian) { wav.append(contentsOf: $0) } // bits/sample

        // data chunk
        wav.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        withUnsafeBytes(of: dataSize.littleEndian) { wav.append(contentsOf: $0) }

        // Near-silent samples (not pure zero to avoid iOS collapsing)
        for i in 0..<numSamples {
            let sample: Int16 = (i % 2 == 0) ? 1 : -1
            withUnsafeBytes(of: sample.littleEndian) { wav.append(contentsOf: $0) }
        }

        return wav
    }

    // MARK: - Audio session interruption handling

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: nil
        ) { [weak self] notification in
            guard let userInfo = notification.userInfo,
                  let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

            if type == .ended {
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else { return }
                    logger.info("Audio interruption ended, reactivating")
                    self.reactivateAudioSession()
                }
            }
        }
    }

    private func removeInterruptionObserver() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
    }

}
