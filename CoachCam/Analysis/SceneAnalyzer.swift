import AVFoundation
import CoreML
import Vision

/// Looks at the live camera feed and works out what's in it.
///
/// - Runs at most `fastHz` times a second (12 by default), never on every frame, to save
///   battery and heat. If an analysis is still running when a frame arrives, the frame
///   is skipped.
/// - Every tick ("fast"): body pose, faces, YOLO objects, light, motion.
/// - Every Nth tick ("slow", about 3×/s): scene labels, horizon, saliency, face landmarks.
///   Slow results are carried over between slow ticks.
///
/// All Vision work happens on its own queue; results are published on the main thread.
final class SceneAnalyzer: ObservableObject {
    @Published private(set) var latest = SceneAnalysis()
    @Published private(set) var ticksPerSecond: Double = 0
    @Published private(set) var modelStatus = "loading…"

    /// Called on the main thread after each analysis (the mode engine listens here).
    var onAnalysis: ((SceneAnalysis) -> Void)?

    private let config = AppConfig.shared
    private let queue = DispatchQueue(label: "coachcam.analysis", qos: .userInitiated)
    private let gate = NSLock()          // Protects `busy` and `lastStart` (touched from two queues).
    private var busy = false
    private var lastStart: CFTimeInterval = 0

    // Only touched on `queue`:
    private var tick = 0
    private var yoloRequest: VNCoreMLRequest?
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let faceRequest: VNDetectFaceRectanglesRequest = {
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3   // Adds face yaw/roll/pitch.
        return r
    }()
    private let lightMeter = LightMeter()
    private let downscaler = FrameDownscaler()
    private var slowLabels: [(label: String, confidence: Float)] = []
    private var slowHorizon: Double?
    private var slowSalient: CGRect?
    private var lastLandmarks: [(faceBox: CGRect, points: [CGPoint])] = []
    private var loggedErrors = Set<String>()
    private var tickTimes: [CFTimeInterval] = []

    private var modelLoadAttempted = false

    /// Loads the model the first time a frame arrives (on `queue`), not in init: SwiftUI may
    /// create throwaway copies of this object, and each would otherwise load the model.
    private func loadModelIfNeeded() {
        guard !modelLoadAttempted else { return }
        modelLoadAttempted = true
        loadObjectModel()
    }

    // MARK: - Model

    /// Loads YOLO11n (compiled by Xcode from Resources/Models/yolo11n.mlpackage).
    private func loadObjectModel() {
        guard let url = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc") else {
            Log.error("YOLO model not found in app bundle, object detection off")
            DispatchQueue.main.async { self.modelStatus = "missing" }
            return
        }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all   // Neural Engine when possible.
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
            request.imageCropAndScaleOption = .scaleFill
            yoloRequest = request
            Log.info("YOLO11n loaded")
            DispatchQueue.main.async { self.modelStatus = "ok" }
        } catch {
            Log.error("YOLO model failed to load: \(error.localizedDescription)")
            DispatchQueue.main.async { self.modelStatus = "error" }
        }
    }

    // MARK: - Frame intake (called on the camera's video queue)

    /// Offers a camera frame. Returns immediately; most frames are skipped on purpose.
    func submit(_ sampleBuffer: CMSampleBuffer, info: FrameInfo) {
        let now = CACurrentMediaTime()
        gate.lock()
        let tooSoon = now - lastStart < 1.0 / config.analysis.fastHz
        if busy || tooSoon {
            gate.unlock()
            return
        }
        busy = true
        lastStart = now
        gate.unlock()

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            markIdle()
            return
        }
        let geometry = FrameGeometry(rotationAngle: info.rotationAngle)
        queue.async {
            self.analyze(pixelBuffer, geometry: geometry, info: info)
            self.markIdle()
        }
    }

    private func markIdle() {
        gate.lock()
        busy = false
        gate.unlock()
    }

    // MARK: - Analysis (on `queue`)

    private func analyze(_ pixelBuffer: CVPixelBuffer, geometry: FrameGeometry, info: FrameInfo) {
        loadModelIfNeeded()
        let start = CACurrentMediaTime()
        tick += 1
        let isSlowTick = tick % max(1, config.analysis.slowEveryNthTick) == 1 || config.analysis.slowEveryNthTick <= 1

        // Vision works on a shrunken copy; normalized coordinates are the same either way.
        let visionBuffer = downscaler.scaled(pixelBuffer, maxDimension: config.analysis.maxVisionDimension)
        let handler = VNImageRequestHandler(cvPixelBuffer: visionBuffer, orientation: geometry.visionOrientation,
                                            options: [:])
        var requests: [VNRequest] = [bodyRequest, faceRequest]
        if let yolo = yoloRequest { requests.append(yolo) }

        let classify = VNClassifyImageRequest()
        let horizon = VNDetectHorizonRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        if isSlowTick { requests += [classify, horizon, saliency] }

        do {
            try handler.perform(requests)
        } catch {
            logOnce("Vision error: \(error.localizedDescription)")
        }

        // People and faces
        let faces = (faceRequest.results ?? [])
        var people = buildPeople(bodies: bodyRequest.results ?? [], faces: faces)

        // Face landmarks (slow ticks only; reused in between)
        if isSlowTick {
            lastLandmarks = []
            if !faces.isEmpty {
                let landmarks = VNDetectFaceLandmarksRequest()
                landmarks.inputFaceObservations = faces
                do {
                    try handler.perform([landmarks])
                    lastLandmarks = (landmarks.results ?? []).map { face in
                        (faceBox: FrameGeometry.upright(fromVision: face.boundingBox),
                         points: Self.landmarkPoints(of: face))
                    }
                } catch {
                    logOnce("Landmarks error: \(error.localizedDescription)")
                }
            }
        }
        for i in people.indices {
            guard let faceBox = people[i].faceBox else { continue }
            if let match = lastLandmarks.max(by: { $0.faceBox.iou(faceBox) < $1.faceBox.iou(faceBox) }),
               match.faceBox.iou(faceBox) > 0.3 {
                people[i].faceLandmarks = match.points
            }
        }

        // Objects (YOLO). "person" boxes also rescue people the pose detector missed.
        var objects: [DetectedObject] = []
        for observation in (yoloRequest?.results as? [VNRecognizedObjectObservation]) ?? [] {
            guard let top = observation.labels.first, top.confidence >= config.analysis.objectConfidence else { continue }
            let box = FrameGeometry.upright(fromVision: observation.boundingBox)
            if top.identifier == "person" {
                let known = people.contains { $0.box.iou(box) > 0.3 || box.fractionInside($0.box) > 0.7 }
                if !known {
                    people.append(PersonInfo(box: box, joints: [:], fullBodyVisible: false))
                }
            } else {
                objects.append(DetectedObject(label: top.identifier, confidence: top.confidence, box: box))
            }
        }
        people.sort { $0.box.area > $1.box.area }   // Biggest (usually closest) first.
        objects.sort { $0.confidence > $1.confidence }

        // Slow results
        if isSlowTick {
            let minConfidence = config.analysis.classificationMinConfidence
            slowLabels = (classify.results ?? [])
                .filter { $0.confidence >= minConfidence }
                .sorted { $0.confidence > $1.confidence }
                .prefix(8)
                .map { (label: $0.identifier, confidence: $0.confidence) }
            slowHorizon = horizon.results?.first.map { Double($0.angle) * 180 / .pi }
            let salient = saliency.results?.first?.salientObjects?.max { $0.boundingBox.area < $1.boundingBox.area }
            slowSalient = salient.map { FrameGeometry.upright(fromVision: $0.boundingBox) }
        }

        // Light and motion
        let measured = lightMeter.measure(pixelBuffer, faceBox: people.first?.faceBox, geometry: geometry,
                                          config: config.light)

        var analysis = SceneAnalysis()
        analysis.timestamp = start
        analysis.isFrontCamera = info.isFrontCamera
        analysis.lensPosition = info.lensPosition
        analysis.horizontalFOV = info.horizontalFOV
        analysis.isMacro = info.isMacro
        analysis.rotationAngle = geometry.angle
        analysis.verticalLines = measured.verticalLines
        analysis.people = people
        analysis.objects = objects
        analysis.labels = slowLabels
        analysis.horizonDegrees = slowHorizon
        analysis.salientBox = slowSalient
        analysis.light = measured.light
        analysis.frameChange = measured.frameChange
        analysis.analysisMs = (CACurrentMediaTime() - start) * 1000

        tickTimes.append(start)
        tickTimes.removeAll { start - $0 > 1 }
        let rate = Double(tickTimes.count)

        DispatchQueue.main.async {
            self.latest = analysis
            self.ticksPerSecond = rate
            self.onAnalysis?(analysis)
        }
    }

    // MARK: - People

    /// Body joints we keep, with readable names.
    private static let joints: [(VNHumanBodyPoseObservation.JointName, String)] = [
        (.nose, "nose"), (.leftEye, "leftEye"), (.rightEye, "rightEye"), (.leftEar, "leftEar"), (.rightEar, "rightEar"),
        (.neck, "neck"), (.leftShoulder, "leftShoulder"), (.rightShoulder, "rightShoulder"),
        (.leftElbow, "leftElbow"), (.rightElbow, "rightElbow"), (.leftWrist, "leftWrist"), (.rightWrist, "rightWrist"),
        (.root, "root"), (.leftHip, "leftHip"), (.rightHip, "rightHip"),
        (.leftKnee, "leftKnee"), (.rightKnee, "rightKnee"), (.leftAnkle, "leftAnkle"), (.rightAnkle, "rightAnkle")
    ]

    private func buildPeople(bodies: [VNHumanBodyPoseObservation], faces: [VNFaceObservation]) -> [PersonInfo] {
        let minJoint = config.analysis.bodyJointConfidence
        var people: [PersonInfo] = []

        for body in bodies {
            guard let points = try? body.recognizedPoints(.all) else { continue }
            var joints: [String: CGPoint] = [:]
            for (jointName, name) in Self.joints {
                if let p = points[jointName], p.confidence >= minJoint {
                    joints[name] = FrameGeometry.upright(fromVision: p.location)
                }
            }
            guard joints.count >= 3 else { continue }
            let xs = joints.values.map(\.x), ys = joints.values.map(\.y)
            var box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)

            // Joints stop at the nose/eyes, so estimate the top of the head.
            var headTop: CGFloat?
            if let nose = joints["nose"], let neck = joints["neck"] {
                headTop = nose.y - (neck.y - nose.y) * 1.1
            }
            if let top = headTop, top < box.minY {
                let clampedTop = max(0, top)
                box = CGRect(x: box.minX, y: clampedTop, width: box.width, height: box.maxY - clampedTop)
            }
            box = box.insetBy(dx: -box.width * 0.08, dy: 0)   // Joints are centers of limbs; widen a bit.

            let hasHead = joints["nose"] != nil || joints["leftEye"] != nil || joints["rightEye"] != nil
            let hasAnkle = joints["leftAnkle"] != nil || joints["rightAnkle"] != nil
            people.append(PersonInfo(box: box.clampedToUnit, headTopY: headTop, joints: joints,
                                     fullBodyVisible: hasHead && hasAnkle))
        }

        // Attach each face to the person it belongs to; faces with no body become people too
        // (close-ups often have no detectable body).
        for face in faces {
            let faceBox = FrameGeometry.upright(fromVision: face.boundingBox)
            let yaw = face.yaw.map { $0.doubleValue * 180 / .pi }
            let roll = face.roll.map { $0.doubleValue * 180 / .pi }
            let pitch = face.pitch.map { $0.doubleValue * 180 / .pi }
            let owner = people.indices.first { i in
                if let nose = people[i].joints["nose"] { return faceBox.insetBy(dx: -0.02, dy: -0.02).contains(nose) }
                return people[i].box.contains(faceBox.center)
            }
            if let i = owner, people[i].faceBox == nil {
                people[i].faceBox = faceBox
                people[i].faceYaw = yaw; people[i].faceRoll = roll; people[i].facePitch = pitch
                if people[i].headTopY == nil { people[i].headTopY = faceBox.minY - faceBox.height * 0.2 }
                people[i].box = people[i].box.union(faceBox).clampedToUnit
            } else {
                // Face only: guess a head-and-shoulders box around it.
                let box = CGRect(x: faceBox.minX - faceBox.width * 0.6, y: faceBox.minY - faceBox.height * 0.25,
                                 width: faceBox.width * 2.2, height: faceBox.height * 2.4)
                var person = PersonInfo(box: box.clampedToUnit, joints: [:], fullBodyVisible: false)
                person.faceBox = faceBox
                person.faceYaw = yaw; person.faceRoll = roll; person.facePitch = pitch
                person.headTopY = faceBox.minY - faceBox.height * 0.2
                people.append(person)
            }
        }
        return people
    }

    /// Eye, nose, lip and face-outline points, converted to upright frame coordinates.
    private static func landmarkPoints(of face: VNFaceObservation) -> [CGPoint] {
        guard let landmarks = face.landmarks else { return [] }
        let regions = [landmarks.leftEye, landmarks.rightEye, landmarks.nose, landmarks.outerLips, landmarks.faceContour]
        let box = face.boundingBox
        var result: [CGPoint] = []
        for region in regions.compactMap({ $0 }) {
            for p in region.normalizedPoints {
                let vision = CGPoint(x: box.minX + p.x * box.width, y: box.minY + p.y * box.height)
                result.append(FrameGeometry.upright(fromVision: vision))
            }
        }
        return result
    }

    private func logOnce(_ message: String) {
        if loggedErrors.insert(message).inserted { Log.warn(message) }
    }
}

extension CGRect {
    /// Clipped to the 0–1 frame.
    var clampedToUnit: CGRect {
        let r = intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.isNull ? .zero : r
    }
}
