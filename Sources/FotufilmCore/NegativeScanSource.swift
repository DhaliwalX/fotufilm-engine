import Foundation

/// What a scan's file says of how it was made and decoded, which a reading's setup is made of
/// (`NegativeScanSetup`): the camera, and the white and matrix its decoder used. It belongs to
/// the decoded scan, not to its edit: another decoder of the same file answers otherwise.
public struct NegativeScanSource: Equatable, Codable, Sendable {
    /// The camera the file names.
    public var camera: CameraIdentity?
    /// The white the file was decoded on: its colour temperature in kelvin, and its chromaticity
    /// (CIE x and y) where the decoder says it.
    public var kelvin: Float?
    public var white: [Float]?
    /// The matrix the decoder mixed the camera's balanced channels into the scan's with, nine
    /// values by rows (`NegativeScanSetup.matrix`). Nil where it is not known.
    public var matrix: [Float]?

    public init(camera: CameraIdentity? = nil, kelvin: Float? = nil, white: [Float]? = nil,
                matrix: [Float]? = nil) {
        self.camera = camera
        self.kelvin = kelvin
        self.white = white
        self.matrix = matrix
    }

    /// The setup a scan from this file is read with under `light`, as `chosen` where the edit
    /// names what took it. Left to the file, it is the camera's measured channels only where the
    /// decoder's matrix is known too: a dense negative's blue follows the matrix too closely to
    /// take the camera's own for another decoder's, and reads better as the generic camera.
    public func setup(light: NegativeScanCrosstalk.Light,
                      camera chosen: NegativeScanSetup.Camera? = nil) -> NegativeScanSetup {
        let rows = matrixRows
        let camera: NegativeScanSetup.Camera
        if let chosen {
            camera = chosen
        } else if rows != nil, let profile = CameraSpectralProfileStore.resolve(self.camera) {
            camera = .profile(profile.id)
        } else {
            camera = .generic
        }
        // Only a measured camera's channels depend on how its file was decoded.
        guard case .profile(let id) = camera, CameraSpectralProfileStore.profile(id: id) != nil
        else { return NegativeScanSetup(light: light, camera: camera) }
        let kelvin = self.kelvin.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let white = self.white.flatMap { xy -> SIMD2<Float>? in
            guard xy.count == 2, xy.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            return SIMD2(xy[0], xy[1])
        }
        return NegativeScanSetup(light: light, camera: camera, kelvin: kelvin, white: white,
                                 matrix: rows)
    }

    /// What a scan from this file is read as taken with where its edit leaves that to the file:
    /// `id` as an edit names a camera (`NegativeScanSetup.Camera.name`), and a measured camera's
    /// `name` as its file says it.
    public var readCamera: (id: String, name: String?) {
        let camera = setup(light: .white).camera
        guard case .profile = camera, let identity = self.camera else { return (camera.name, nil) }
        let make = identity.make?.trimmingCharacters(in: .whitespaces) ?? ""
        let model = identity.model?.trimmingCharacters(in: .whitespaces) ?? ""
        // Some cameras' models begin with their makers' names.
        let name = (model.lowercased().hasPrefix(make.lowercased()) ? model : "\(make) \(model)")
            .trimmingCharacters(in: .whitespaces)
        return (camera.name, name.isEmpty ? nil : name)
    }

    /// `matrix` as rows, where it is one a decoder could have used.
    private var matrixRows: [SIMD3<Float>]? {
        guard let matrix, matrix.count == 9, matrix.allSatisfy(\.isFinite) else { return nil }
        let rows = (0..<3).map { SIMD3(matrix[3 * $0], matrix[3 * $0 + 1], matrix[3 * $0 + 2]) }
        return NegativeScanDecoderMatrix.plausible(rows) ? rows : nil
    }
}
