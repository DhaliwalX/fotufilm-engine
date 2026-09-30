/// Additional light arriving at the film behind the camera gate. Values are photographic
/// R/G/B/donor record exposure, never display RGB or alpha. The source scene still passes
/// through lens diffusion; this field joins it after the gate and before film optics.
///
/// The writer receives a zeroed, interleaved four-record buffer for each tile, including
/// its spatial apron. Use the region's absolute coordinates so overlapping tiles agree.
/// Do not retain the borrowed pointer. All written values must be finite and nonnegative.
public struct FilmRecordExposure: Sendable {
    public struct Region: Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let frameWidth: Int
        public let frameHeight: Int
    }

    private let writer: @Sendable (Region, UnsafeMutableBufferPointer<Float>) throws -> Void

    public init(_ writer: @escaping @Sendable (Region, UnsafeMutableBufferPointer<Float>) throws -> Void) {
        self.writer = writer
    }

    func fill(region: Region, into buffer: UnsafeMutableBufferPointer<Float>) throws {
        try writer(region, buffer)
        guard buffer.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw TransportError.invalid("additional film record exposure must be finite and nonnegative")
        }
    }
}
