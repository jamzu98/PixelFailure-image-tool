import SwiftUI

/// Vision face landmarks resolved into canvas space (y-down).
nonisolated struct FaceLandmarkPoints: Sendable, Equatable {
    var box: CGRect
    var contour: [CGPoint] = []
    var leftEye: [CGPoint] = []
    var rightEye: [CGPoint] = []
    var leftBrow: [CGPoint] = []
    var rightBrow: [CGPoint] = []
    var outerLips: [CGPoint] = []
    var innerLips: [CGPoint] = []
    var nose: [CGPoint] = []
    var leftPupil: [CGPoint] = []
    var rightPupil: [CGPoint] = []
}

nonisolated struct FaceFeatures: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let face = FaceFeatures(rawValue: 1 << 0)
    static let skin = FaceFeatures(rawValue: 1 << 1)
    static let eyes = FaceFeatures(rawValue: 1 << 2)
    static let brows = FaceFeatures(rawValue: 1 << 3)
    static let lips = FaceFeatures(rawValue: 1 << 4)
    static let nose = FaceFeatures(rawValue: 1 << 5)
    static let pupils = FaceFeatures(rawValue: 1 << 6)

    static let all: [(FaceFeatures, String, String)] = [
        (.face, "Face", "face.smiling"),
        (.skin, "Skin", "circle.lefthalf.filled"),
        (.eyes, "Eyes", "eye"),
        (.brows, "Brows", "eyebrow"),
        (.lips, "Lips", "mouth"),
        (.nose, "Nose", "nose"),
        (.pupils, "Pupils", "circle.circle"),
    ]
}

/// Turns landmark polylines into selectable regions. Vision has no face
/// parsing, so the face outline closes the jaw contour with a forehead arc
/// estimated from the brow line.
nonisolated enum FaceRegionBuilder {
    static func path(_ face: FaceLandmarkPoints, features: FaceFeatures) -> Path {
        var result = CGMutablePath()
        func add(_ p: CGPath) {
            result = result.isEmpty ? p.mutableCopy()! : result.union(p, using: .evenOdd).mutableCopy()!
        }
        if features.contains(.face) { add(faceOutline(face)) }
        if features.contains(.skin) {
            var holes = CGMutablePath()
            for hole in [eyes(face), brows(face), lipsOuter(face)] where !hole.isEmpty {
                holes = holes.isEmpty ? hole.mutableCopy()! : holes.union(hole, using: .evenOdd).mutableCopy()!
            }
            add(holes.isEmpty ? faceOutline(face) : faceOutline(face).subtracting(holes, using: .evenOdd))
        }
        if features.contains(.eyes) { add(eyes(face)) }
        if features.contains(.brows) { add(brows(face)) }
        if features.contains(.lips) { add(lips(face)) }
        if features.contains(.nose), face.nose.count >= 3 { add(smoothClosed(face.nose)) }
        if features.contains(.pupils) { add(pupils(face)) }
        return Path(result)
    }

    /// Jaw contour + forehead arc; an upward-extended ellipse without landmarks.
    static func faceOutline(_ face: FaceLandmarkPoints) -> CGPath {
        let box = face.box
        guard face.contour.count >= 3 else {
            let extended = CGRect(x: box.minX, y: box.minY - box.height * 0.15,
                                  width: box.width, height: box.height * 1.15)
            return CGPath(ellipseIn: extended, transform: nil)
        }
        // Order the jaw left→right so the arc closes it cleanly.
        var jaw = face.contour
        if let first = jaw.first, let last = jaw.last, first.x > last.x { jaw.reverse() }
        let browPoints = face.leftBrow + face.rightBrow
        let eyePoints = face.leftEye + face.rightEye
        let browTop = browPoints.map(\.y).min() ?? box.minY + box.height * 0.25
        let eyeCenter = eyePoints.isEmpty ? browTop + box.height * 0.1
            : eyePoints.map(\.y).reduce(0, +) / CGFloat(eyePoints.count)
        // Forehead top: about one brow-to-eye distance above the brows, at
        // least to the top of Vision's box, at most 15% beyond it.
        let foreheadTop = min(max(browTop - abs(eyeCenter - browTop) * 2.2, box.minY - box.height * 0.15),
                              box.minY)
        let left = jaw.first!, right = jaw.last!
        let path = CGMutablePath()
        path.addLines(between: smooth(jaw))
        // Arc from right temple over the forehead back to the left temple.
        let midX = (left.x + right.x) / 2
        let controlY = foreheadTop - (min(left.y, right.y) - foreheadTop) * 0.35
        path.addCurve(to: CGPoint(x: midX, y: foreheadTop),
                      control1: CGPoint(x: right.x, y: (right.y + controlY) / 2),
                      control2: CGPoint(x: right.x - (right.x - midX) * 0.45, y: foreheadTop))
        path.addCurve(to: left,
                      control1: CGPoint(x: left.x + (midX - left.x) * 0.45, y: foreheadTop),
                      control2: CGPoint(x: left.x, y: (left.y + controlY) / 2))
        path.closeSubpath()
        return path
    }

    static func eyes(_ face: FaceLandmarkPoints) -> CGPath {
        let path = CGMutablePath()
        for eye in [face.leftEye, face.rightEye] where eye.count >= 3 {
            path.addPath(smoothClosed(eye))
        }
        return path
    }

    static func brows(_ face: FaceLandmarkPoints) -> CGPath {
        let path = CGMutablePath()
        let width = max(face.box.height * 0.04, 1)
        for brow in [face.leftBrow, face.rightBrow] where brow.count >= 2 {
            let line = CGMutablePath()
            line.addLines(between: brow)
            path.addPath(line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round,
                                   miterLimit: 4))
        }
        return path
    }

    static func lipsOuter(_ face: FaceLandmarkPoints) -> CGPath {
        face.outerLips.count >= 3 ? smoothClosed(face.outerLips) : CGMutablePath()
    }

    /// Outer lips minus the mouth opening.
    static func lips(_ face: FaceLandmarkPoints) -> CGPath {
        let outer = lipsOuter(face)
        guard !outer.isEmpty else { return outer }
        guard face.innerLips.count >= 3 else { return outer }
        return outer.subtracting(smoothClosed(face.innerLips), using: .evenOdd)
    }

    static func pupils(_ face: FaceLandmarkPoints) -> CGPath {
        let path = CGMutablePath()
        for (pupil, eye) in [(face.leftPupil, face.leftEye), (face.rightPupil, face.rightEye)] {
            guard let center = centroid(pupil.isEmpty ? eye : pupil) else { continue }
            let xs = eye.map(\.x)
            let eyeWidth = (xs.max() ?? center.x) - (xs.min() ?? center.x)
            let radius = max(eyeWidth * 0.2, face.box.width * 0.02)
            path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                       width: radius * 2, height: radius * 2))
        }
        return path
    }

    // MARK: Geometry helpers

    static func centroid(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Closed Catmull-Rom smoothing (4 samples per segment).
    static func smoothClosed(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        let smoothed = catmullRom(points, closed: true)
        guard let first = smoothed.first else { return path }
        path.move(to: first)
        path.addLines(between: smoothed)
        path.closeSubpath()
        return path
    }

    static func smooth(_ points: [CGPoint]) -> [CGPoint] {
        catmullRom(points, closed: false)
    }

    private static func catmullRom(_ p: [CGPoint], closed: Bool, samples: Int = 4) -> [CGPoint] {
        guard p.count >= 3 else { return p }
        let n = p.count
        func at(_ i: Int) -> CGPoint {
            closed ? p[(i % n + n) % n] : p[min(max(i, 0), n - 1)]
        }
        var out: [CGPoint] = []
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2)
            for s in 0..<samples {
                let t = CGFloat(s) / CGFloat(samples)
                let t2 = t * t, t3 = t2 * t
                func c(_ a: CGFloat, _ b: CGFloat, _ cc: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + cc) * t + (2 * a - 5 * b + 4 * cc - d) * t2 + (-a + 3 * b - 3 * cc + d) * t3)
                }
                out.append(CGPoint(x: c(p0.x, p1.x, p2.x, p3.x), y: c(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        if !closed, let last = p.last { out.append(last) }
        return out
    }
}
