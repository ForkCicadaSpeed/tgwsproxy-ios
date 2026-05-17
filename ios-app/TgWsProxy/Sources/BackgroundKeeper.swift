import Foundation
import AVFoundation
import UIKit
import os.log

private let logger = Logger(subsystem: "com.tgwsproxy.app", category: "BackgroundKeeper")

// BackgroundKeeper keeps the local MTProto proxy alive in the background:
//   1. Silent AVAudioEngine playback (UIBackgroundModes = "audio")
//   2. A long UIApplication background task as an extra safety net
//
// Live Activity / Dynamic Island only shows state, it does NOT keep the
// process alive on its own.

@MainActor
@available(iOS 17.0, *)
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var audioEngine = AVAudioEngine()
    private var audioPlayer: AVAudioPlayerNode?
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    private var interruptionObserver: NSObjectProtocol?
    private(set) var isRunning = false

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("BackgroundKeeper start")

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
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
            if !(audioPlayer?.isPlaying ?? false) {
                logger.info("Audio player was stopped, restarting silent audio")
                // Stop engine without deactivating session
                audioPlayer?.stop()
                audioEngine.stop()
                audioEngine.reset()
                audioEngine = AVAudioEngine()
                audioPlayer = nil
                startSilentAudio()
            }
        } catch {
            logger.warning("Failed to reactivate audio session: \(error.localizedDescription)")
        }
        startBackgroundTask()
    }

    // MARK: - UIApplication background task

    private func startBackgroundTask() {
        endBackgroundTask()
        bgTaskID = UIApplication.shared.beginBackgroundTask(withName: "TgWsProxyKeepAlive") { [weak self] in
            // Expiration handler — release the task; audio / location keep us alive.
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
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            try session.setActive(true, options: [])
        } catch {
            logger.warning("Audio session failed: \(error.localizedDescription)")
            return
        }

        let mainMixer = audioEngine.mainMixerNode
        let format = mainMixer.outputFormat(forBus: 0)
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else {
            logger.warning("Invalid audio format (sampleRate=0), skipping silent audio")
            return
        }
        let frameCount = AVAudioFrameCount(sampleRate * 2) // 2 seconds of buffer

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            logger.warning("Failed to allocate silent audio buffer")
            return
        }
        buffer.frameLength = frameCount

        // Fill with extremely quiet noise so the audio engine doesn't get
        // collapsed by the system as "all-silence".
        if let channelData = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            for channel in 0..<channels {
                let pointer = channelData[channel]
                for frame in 0..<Int(frameCount) {
                    // -120 dB sine-ish noise, inaudible but non-zero
                    pointer[frame] = (frame & 1 == 0) ? 0.0000001 : -0.0000001
                }
            }
        }

        let playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: mainMixer, format: format)

        do {
            try audioEngine.start()
            playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            playerNode.play()
            self.audioPlayer = playerNode
            logger.info("Silent audio engine started")
        } catch {
            logger.warning("Audio engine start failed: \(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        audioPlayer?.stop()
        audioEngine.stop()
        audioEngine.reset()
        audioEngine = AVAudioEngine()
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
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
