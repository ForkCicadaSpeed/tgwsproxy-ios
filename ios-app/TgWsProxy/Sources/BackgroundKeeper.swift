import Foundation
import AVFoundation
import CoreLocation
import UIKit
import os.log

private let logger = Logger(subsystem: "com.tgwsproxy.app", category: "BackgroundKeeper")

// BackgroundKeeper combines several techniques so that the local MTProto
// proxy keeps running while the app is in the background:
//   1. Silent AVAudioEngine playback (UIBackgroundModes = "audio")
//   2. Background location updates  (UIBackgroundModes = "location")
//   3. A long UIApplication background task as an extra safety net
//
// Live Activity / Dynamic Island only shows state, it does NOT keep the
// process alive on its own.

@MainActor
@available(iOS 17.0, *)
final class BackgroundKeeper: NSObject, CLLocationManagerDelegate {
    static let shared = BackgroundKeeper()

    private let locationManager = CLLocationManager()
    private let audioEngine = AVAudioEngine()
    private var audioPlayer: AVAudioPlayerNode?
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
    private(set) var isRunning = false

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        locationManager.distanceFilter = 500
    }

    // MARK: - Public API

    func start() {
        guard !isRunning else { return }
        isRunning = true
        logger.info("BackgroundKeeper start")

        registerInterruptionObserver()
        startBackgroundTask()
        startSilentAudio()
        startLocation()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        logger.info("BackgroundKeeper stop")

        removeInterruptionObserver()
        stopSilentAudio()
        stopLocation()
        endBackgroundTask()
    }

    func reactivateAudioSession() {
        guard isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true, options: [])
            if !(audioPlayer?.isPlaying ?? false) {
                logger.info("Audio player was stopped, restarting silent audio")
                stopSilentAudio()
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
        if audioEngine.isRunning { audioEngine.stop() }
        audioPlayer = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    // MARK: - Audio session interruption handling

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    private func removeInterruptionObserver() {
        NotificationCenter.default.removeObserver(
            self,
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc nonisolated private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        if type == .ended {
            Task { @MainActor in
                guard self.isRunning else { return }
                logger.info("Audio interruption ended, reactivating")
                self.reactivateAudioSession()
            }
        }
    }

    // MARK: - Background location (secondary keep-alive)

    private func startLocation() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            locationManager.requestAlwaysAuthorization()
        default:
            break
        }
        locationManager.startUpdatingLocation()
    }

    private func stopLocation() {
        locationManager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // No-op: we only need the OS to keep the process scheduled.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore — audio + UIBackgroundTask are still active.
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // If user grants always permission while we're running, the OS will
        // keep delivering updates automatically — nothing to do here.
    }
}
