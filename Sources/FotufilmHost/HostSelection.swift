import Foundation
#if canImport(FotufilmCore)
import FotufilmCore
#endif
#if canImport(FotufilmEditModel)
import FotufilmEditModel
#endif

/// A selective adjustment as the web editor saves it (`edit.selective`, web/src/selective.js):
/// a sampled scene colour or light, how far from it the selection reaches, and the develop it
/// gets. The weight reads the undeveloped scene, so a selection holds when the film changes.
struct HostSelection: Decodable {
    var kind = "color"
    var point: [Double]?
    var sample: [Double]?
    var range = 0.25
    var softness = 0.5
    var params: [String: Double]?
    var localTone: Bool?
    var gradeSpace: Bool?
    /// A subject's rim against the detector's, -1…1 (negative eats in), and its softness, 0…1:
    /// the Mac app's `subjectEdge` and `subjectFeather`.
    var subjectEdge = 0.0
    var subjectFeather = 0.35

    private enum CodingKeys: String, CodingKey {
        case kind, point, sample, range, softness, params, localTone, gradeSpace
        case subjectEdge, subjectFeather
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "color"
        point = try values.decodeIfPresent([Double].self, forKey: .point)
        sample = try values.decodeIfPresent([Double].self, forKey: .sample)
        range = try values.decodeIfPresent(Double.self, forKey: .range) ?? 0.25
        softness = try values.decodeIfPresent(Double.self, forKey: .softness) ?? 0.5
        params = try values.decodeIfPresent([String: Double].self, forKey: .params)
        localTone = try values.decodeIfPresent(Bool.self, forKey: .localTone)
        gradeSpace = try values.decodeIfPresent(Bool.self, forKey: .gradeSpace)
        subjectEdge = try values.decodeIfPresent(Double.self, forKey: .subjectEdge) ?? 0
        subjectFeather = try values.decodeIfPresent(Double.self, forKey: .subjectFeather) ?? 0.35
    }

    /// A subject selection takes every subject until one is clicked, as the Mac app's does.
    var isActive: Bool { kind == "subject" || sample?.count == 3 }
    var isSubject: Bool { kind == "subject" }

    /// The edit the selected area develops with: the photograph's, with the selection's own
    /// light and colour settings over it.
    func develop(_ edit: WebNativeEdit) -> WebNativeEdit {
        var local = edit
        var params = edit.edit.params ?? [:]
        for (key, value) in self.params ?? [:] { params[key] = value }
        local.edit.params = params
        if let localTone { local.edit.localTone = localTone }
        if let gradeSpace { local.edit.gradeSpace = gradeSpace }
        return local
    }

    private static func luma(_ c: SIMD3<Double>) -> Double {
        0.2627002 * c.x + 0.6779981 * c.y + 0.0593017 * c.z
    }

    private static func chroma(_ c: SIMD3<Double>) -> SIMD2<Double> {
        let y = max(luma(c), 1e-4)
        return SIMD2((c.x - y) / (y + 0.25), (c.z - y) / (y + 0.25))
    }

    /// How much of the selection a scene colour is (`selectionWeight`).
    func weight(_ rgb: SIMD3<Double>) -> Double {
        guard let sample, sample.count == 3 else { return 0 }
        let target = SIMD3(sample[0], sample[1], sample[2])
        let distance: Double
        if kind == "light" {
            distance = abs(Self.luma(rgb) - Self.luma(target))
        } else {
            let a = Self.chroma(rgb), b = Self.chroma(target)
            distance = hypot(a.x - b.x, a.y - b.y)
        }
        let inner = range * (1 - softness)
        let t = max(0, min(1, (distance - inner) / max(1e-9, range - inner)))
        return 1 - t * t * (3 - 2 * t)
    }

    /// Blends the selection's develop over the photograph's in linear light
    /// (`compositeSelection`). With `showMask` the selection shows white over a dimmed picture.
    /// `subject` supplies the weights of a subject selection; a colour or light selection reads
    /// them off the scene.
    func composite(ground: [UInt8], selected: [UInt8]?, scene: [Float], width: Int, height: Int,
                   showMask: Bool, subject: [Float]? = nil) -> [UInt8] {
        var result = ground
        let decode: [Double] = (0..<256).map { Double(ColorScience.srgbToLinear(Float($0) / 255)) }
        result.withUnsafeMutableBufferPointer { out in
            let out = out
            SceneGeometry.concurrent(height) { y in
                for i in (y * width)..<((y + 1) * width) {
                    let weight = subject.map { Double($0[i]) }
                        ?? self.weight(SIMD3(Double(scene[i * 4]), Double(scene[i * 4 + 1]),
                                             Double(scene[i * 4 + 2])))
                    guard weight > 0 || showMask else { continue }
                    for c in 0..<3 {
                        let base = decode[Int(ground[i * 4 + c])]
                        let local = showMask ? 1 : decode[Int(selected![i * 4 + c])]
                        let mixed = (showMask ? base * 0.3 : base) * (1 - weight) + local * weight
                        out[i * 4 + c] = UInt8(clamp(
                            ColorScience.linearToSrgb(Float(mixed)) * 255 + 0.5, 0, 255))
                    }
                }
            }
        }
        return result
    }

    /// The same blend over developed linear light, RGBA floats, as a deep movie export delivers
    /// it: every channel, the HDR relight in alpha too, mixed by the selection's weight.
    func composite(ground: inout [Float], selected: [Float], scene: [Float], width: Int,
                   height: Int, subject: [Float]? = nil) {
        ground.withUnsafeMutableBufferPointer { out in
            let out = out
            SceneGeometry.concurrent(height) { y in
                for i in (y * width)..<((y + 1) * width) {
                    let weight = Float(subject.map { Double($0[i]) }
                        ?? self.weight(SIMD3(Double(scene[i * 4]), Double(scene[i * 4 + 1]),
                                             Double(scene[i * 4 + 2]))))
                    guard weight > 0 else { continue }
                    for c in 0..<4 {
                        out[i * 4 + c] = out[i * 4 + c] * (1 - weight) + selected[i * 4 + c] * weight
                    }
                }
            }
        }
    }
}
