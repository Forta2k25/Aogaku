//
//  LecturePhotoCapture.swift
//  Aogaku
//
//  授業ノート(AI)機能: プリント/スライド/黒板の撮影
//
//  AVCapturePhotoOutput.capturePhoto はOSがシャッター音を強制する場合があるため使わず、
//  プレビュー用の連続映像フレームから1枚を取り出す方式で無音撮影する。
//

import AVFoundation
import UIKit

final class LecturePhotoCapture: NSObject {

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "lecture.photo.session")
    private var pendingCaptureCompletion: ((UIImage?) -> Void)?
    private var configured = false
    private var device: AVCaptureDevice?
    private var requestedVideoOrientation: AVCaptureVideoOrientation = .portrait

    /// 現在のデバイスで指定可能な最大ズーム倍率(取得できるまでは1倍)
    var maxZoomFactor: CGFloat {
        min(device?.activeFormat.videoMaxZoomFactor ?? 1, 8)
    }

    /// 同一インスタンスを使い回す(向き更新のため参照を保持する必要がある)
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }
        session.commitConfiguration()
        self.device = device
        let orientation = requestedVideoOrientation
        DispatchQueue.main.async { [weak self] in
            self?.updateVideoOrientation(orientation)
        }
    }

    /// ピンチ操作等からズーム倍率を設定する(1.0〜maxZoomFactorにクランプ)
    func setZoomFactor(_ factor: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.device else { return }
            let clamped = max(1.0, min(factor, self.maxZoomFactor))
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                // ズーム設定に失敗しても撮影自体は継続できるため無視する
            }
        }
    }

    /// プレビュー映像の次フレームを静止画として取得する(シャッター音は鳴らない)
    func captureFrame(completion: @escaping (UIImage?) -> Void) {
        sessionQueue.async { [weak self] in
            self?.pendingCaptureCompletion = completion
        }
    }

    /// 端末の向きに合わせてプレビューと撮影バッファの向きを更新する。
    /// アプリ自体はPortrait固定のため、横向きでの撮影に対応させるにはここで手動対応する。
    func updateVideoOrientation(_ orientation: AVCaptureVideoOrientation) {
        requestedVideoOrientation = orientation

        if #available(iOS 17.0, *), let device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            let previewAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            let captureAngle = coordinator.videoRotationAngleForHorizonLevelCapture

            if let previewConnection = previewLayer.connection,
               previewConnection.isVideoRotationAngleSupported(previewAngle) {
                previewConnection.videoRotationAngle = previewAngle
            }
            sessionQueue.async { [weak self] in
                guard let self,
                      let outputConnection = self.videoOutput.connection(with: .video),
                      outputConnection.isVideoRotationAngleSupported(captureAngle) else { return }
                outputConnection.videoRotationAngle = captureAngle
            }
            return
        }

        if let previewConnection = previewLayer.connection, previewConnection.isVideoOrientationSupported {
            previewConnection.videoOrientation = orientation
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if let outputConnection = self.videoOutput.connection(with: .video), outputConnection.isVideoOrientationSupported {
                outputConnection.videoOrientation = orientation
            }
        }
    }
}

extension LecturePhotoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let completion = pendingCaptureCompletion else { return }
        pendingCaptureCompletion = nil

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        // videoOrientationを都度更新しているため、バッファは既に正しい向きで届く
        let image = UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        DispatchQueue.main.async { completion(image) }
    }
}
