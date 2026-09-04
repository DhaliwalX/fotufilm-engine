import Foundation

#if canImport(FotufilmCore)
import FotufilmCore
#endif

/// Reads DNG `WarpRectilinear` (opcode 1) and `FixVignetteRadial` (opcode 3) into a
/// `LensCorrection`. Catalogue profiles take precedence. Tangential terms, off-centre optical
/// centres, and other opcodes are rejected because the radius-indexed renderer cannot represent
/// them.
public enum DNGOpcodes {

    /// What a file turned out to say about its lens.
    public struct Embedded: Equatable, Sendable {
        /// The correction to apply. Never an identity — `read` returns nil rather than this.
        public var correction: LensCorrection
        /// Whether the geometry came from the file, as opposed to only the falloff.
        public var hasGeometry: Bool
        /// Whether the falloff came from the file.
        public var hasVignetting: Bool
        /// Anything found and refused, in words a person could be shown.
        public var declined: [String]

        public init(correction: LensCorrection, hasGeometry: Bool,
                    hasVignetting: Bool, declined: [String] = []) {
            self.correction = correction
            self.hasGeometry = hasGeometry
            self.hasVignetting = hasVignetting
            self.declined = declined
        }
    }

    /// Reads the lens opcodes out of DNG bytes, or nil when there are none to read.
    ///
    /// Cheap enough to ask on every pass — it walks the directory structure and a few dozen bytes of
    /// payload in place, never copying the file and never touching the image data.
    public static func read(_ data: Data) -> Embedded? {
        data.withUnsafeBytes { read($0) }
    }

    private static func read(_ bytes: UnsafeRawBufferPointer) -> Embedded? {
        guard let file = TIFFFile(bytes) else { return nil }
        guard let directory = file.lensDirectory() else { return nil }

        var warp: LensCorrection.PlaneWarp?
        var vignetting: LensCorrection.Vignetting = .none
        var declined: [String] = []

        // OpcodeList2 runs on the linearized mosaic and OpcodeList3 after demosaic; which list a
        // camera writes its lens correction into varies, so both are read. List 1 runs before
        // linearization and never carries these.
        for tag in [Tag.opcodeList2, Tag.opcodeList3] {
            guard let bytes = file.undefinedBytes(tag, in: directory) else { continue }
            for opcode in opcodes(in: bytes) {
                switch opcode.id {
                case 1:
                    guard warp == nil else { continue }
                    switch warpRectilinear(opcode.payload) {
                    case .success(let read): warp = read
                    case .refused(let why): declined.append(why)
                    case .absent: break
                    }
                case 3:
                    guard vignetting.isIdentity else { continue }
                    switch fixVignetteRadial(opcode.payload) {
                    case .success(let read): vignetting = read
                    case .refused(let why): declined.append(why)
                    case .absent: break
                    }
                default:
                    continue
                }
            }
        }

        guard warp != nil || !vignetting.isIdentity else {
            // Nothing usable. Still worth reporting a refusal, so a photographer looking at an
            // uncorrected frame can be told why rather than left guessing.
            return declined.isEmpty
                ? nil
                : Embedded(correction: .none, hasGeometry: false,
                           hasVignetting: false, declined: declined)
        }

        // The opcodes are written against the sensor's active area; what the decoder returns is
        // the default crop inside it. Both radii are normalized to their own half-diagonal, so the
        // polynomials have to be re-expressed against the smaller frame.
        let scale = file.deliveredRadiusScale(in: directory)
        var correction = LensCorrection(vignetting: vignetting.rescalingRadius(by: scale))
        correction.planeWarp = warp?.rescalingRadius(by: scale)
        guard !correction.isIdentity else { return nil }
        return Embedded(correction: correction, hasGeometry: warp != nil,
                        hasVignetting: !vignetting.isIdentity, declined: declined)
    }

    // MARK: - The two opcodes

    private enum Reading<T> {
        case success(T)
        /// Found, understood, and refused — with the reason.
        case refused(String)
        /// Not there, or too short to be what it claims.
        case absent
    }

    /// How far off centre an optical centre may sit before the warp is refused, as a fraction of the
    /// frame. A hundredth of a percent is a rounding difference in how the camera wrote 0.5; a
    /// tenth of a percent is six pixels on a full-frame sensor, which would be visible as a smear on
    /// one side of the picture if it were applied about the middle instead.
    private static let centreTolerance = 0.001

    /// `WarpRectilinear`: per plane, a radial scale factor as an even polynomial in radius, plus
    /// tangential terms and the optical centre.
    private static func warpRectilinear(_ payload: [UInt8]) -> Reading<LensCorrection.PlaneWarp> {
        var reader = BigEndianReader(payload)
        guard let planes = reader.uint32(), planes == 1 || planes == 3 else { return .absent }
        var factors: [LensCorrection.EvenPolynomial] = []
        var tangential = 0.0
        for _ in 0..<planes {
            guard let kr0 = reader.double(), let kr1 = reader.double(),
                  let kr2 = reader.double(), let kr3 = reader.double(),
                  let kt0 = reader.double(), let kt1 = reader.double()
            else { return .absent }
            factors.append(LensCorrection.EvenPolynomial(
                k0: Float(kr0), k1: Float(kr1), k2: Float(kr2), k3: Float(kr3)))
            tangential = max(tangential, max(abs(kt0), abs(kt1)))
        }
        guard let cx = reader.double(), let cy = reader.double() else { return .absent }

        guard tangential == 0 else {
            return .refused("The file corrects for a lens mounted slightly off axis, which this app cannot undo. Its distortion correction was left alone.")
        }
        guard abs(cx - 0.5) <= centreTolerance, abs(cy - 0.5) <= centreTolerance else {
            return .refused("The file's optical centre is away from the middle of the frame, which this app cannot undo. Its distortion correction was left alone.")
        }

        let warp = planes == 1
            ? LensCorrection.PlaneWarp(red: factors[0], green: factors[0],
                                       blue: factors[0])
            : LensCorrection.PlaneWarp(red: factors[0], green: factors[1],
                                       blue: factors[2])
        return warp.isIdentity ? .absent : .success(warp)
    }

    /// `FixVignetteRadial`: the gain to multiply by, as an even polynomial to r¹⁰, plus the centre
    /// of the falloff.
    private static func fixVignetteRadial(_ payload: [UInt8]) -> Reading<LensCorrection.Vignetting> {
        var reader = BigEndianReader(payload)
        guard let k0 = reader.double(), let k1 = reader.double(),
              let k2 = reader.double(), let k3 = reader.double(),
              let k4 = reader.double(),
              let cx = reader.double(), let cy = reader.double()
        else { return .absent }
        guard abs(cx - 0.5) <= centreTolerance, abs(cy - 0.5) <= centreTolerance else {
            return .refused("The file's falloff is centred away from the middle of the frame, which this app cannot undo. Its vignetting correction was left alone.")
        }
        let read = LensCorrection.Vignetting.radialGain(
            k0: Float(k0), k1: Float(k1), k2: Float(k2), k3: Float(k3),
            k4: Float(k4))
        return read.isIdentity ? .absent : .success(read)
    }

    // MARK: - The opcode stream

    private struct Opcode {
        var id: UInt32
        var payload: [UInt8]
    }

    /// Walks one opcode list. The stream is big-endian whatever the file's own byte order is — the
    /// DNG spec fixes it, so that an opcode list can be copied between files unchanged.
    private static func opcodes(in bytes: [UInt8]) -> [Opcode] {
        var reader = BigEndianReader(bytes)
        guard let count = reader.uint32(), count < 4096 else { return [] }
        var found: [Opcode] = []
        for _ in 0..<count {
            guard let id = reader.uint32(),
                  reader.skip(8),                       // spec version, then flags
                  let length = reader.uint32(),
                  let payload = reader.bytes(Int(length))
            else { break }
            found.append(Opcode(id: id, payload: payload))
        }
        return found
    }
}

// MARK: - Rescaling a polynomial onto a different frame

extension LensCorrection.EvenPolynomial {
    /// The same curve, re-expressed for a radius measured against a frame `scale` times as wide.
    ///
    /// Exact rather than a refit: substituting `s·r` into `k₀ + k₁r² + k₂r⁴ + k₃r⁶` scales each
    /// coefficient by the matching power of s and leaves an even polynomial of the same order.
    func rescalingRadius(by scale: Float) -> Self {
        guard scale != 1 else { return self }
        let s2 = scale * scale
        return Self(k0: k0, k1: k1 * s2, k2: k2 * s2 * s2,
                    k3: k3 * s2 * s2 * s2)
    }
}

extension LensCorrection.PlaneWarp {
    func rescalingRadius(by scale: Float) -> Self {
        Self(red: red.rescalingRadius(by: scale),
             green: green.rescalingRadius(by: scale),
             blue: blue.rescalingRadius(by: scale))
    }
}

extension LensCorrection.Vignetting {
    func rescalingRadius(by scale: Float) -> Self {
        guard case .radialGain(let k0, let k1, let k2, let k3, let k4) = self,
              scale != 1 else { return self }
        let s2 = scale * scale
        var power = s2
        let a = k0 * power; power *= s2
        let b = k1 * power; power *= s2
        let c = k2 * power; power *= s2
        let d = k3 * power; power *= s2
        return .radialGain(k0: a, k1: b, k2: c, k3: d, k4: k4 * power)
    }
}

// MARK: - Just enough TIFF

/// DNG tags required to locate lens opcodes and the delivered crop.
private enum Tag {
    static let newSubFileType: UInt16 = 254
    static let subIFDs: UInt16 = 330
    static let defaultCropOrigin: UInt16 = 50719
    static let defaultCropSize: UInt16 = 50720
    static let activeArea: UInt16 = 50829
    static let opcodeList2: UInt16 = 51009
    static let opcodeList3: UInt16 = 51022
}

/// Minimal TIFF directory reader for DNG lens tags, which ImageIO does not expose.
private struct TIFFFile {
    /// Borrowed file bytes. All offsets are bounds-checked; image data is not copied.
    let bytes: UnsafeRawBufferPointer
    let bigEndian: Bool
    private(set) var firstDirectory: Int

    init?(_ buffer: UnsafeRawBufferPointer) {
        guard buffer.count >= 8 else { return nil }
        switch (buffer[0], buffer[1]) {
        case (0x49, 0x49): bigEndian = false
        case (0x4D, 0x4D): bigEndian = true
        default: return nil
        }
        bytes = buffer
        firstDirectory = 0    // so the readers below may be called
        // 42 is TIFF. 43 is BigTIFF, whose directories are shaped differently; DNG does not use it.
        guard word(2) == 42 else { return nil }
        let offset = long(4)
        guard offset >= 8, offset < UInt32(buffer.count) else { return nil }
        firstDirectory = Int(offset)
    }

    // MARK: primitives

    private func word(_ at: Int) -> UInt16 {
        guard at + 1 < bytes.count else { return 0 }
        return bigEndian
            ? UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
            : UInt16(bytes[at + 1]) << 8 | UInt16(bytes[at])
    }

    private func long(_ at: Int) -> UInt32 {
        guard at + 3 < bytes.count else { return 0 }
        let b = (UInt32(bytes[at]), UInt32(bytes[at + 1]), UInt32(bytes[at + 2]),
                 UInt32(bytes[at + 3]))
        return bigEndian
            ? b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3
            : b.3 << 24 | b.2 << 16 | b.1 << 8 | b.0
    }

    // MARK: directories

    struct Entry {
        var type: UInt16
        var count: UInt32
        /// Where the values are: the entry's own four bytes when they fit, otherwise the offset
        /// those four bytes hold.
        var valueOffset: Int
    }

    typealias Directory = [UInt16: Entry]

    private func directory(at offset: Int) -> Directory? {
        guard offset + 2 <= bytes.count else { return nil }
        let count = Int(word(offset))
        guard count > 0, offset + 2 + count * 12 <= bytes.count else { return nil }
        var entries = Directory(minimumCapacity: count)
        for i in 0..<count {
            let at = offset + 2 + i * 12
            let type = word(at + 2)
            let elements = long(at + 4)
            let size = UInt32(Self.typeSize(type))
            guard size > 0 else { continue }
            let span = elements.multipliedReportingOverflow(by: size)
            guard !span.overflow else { continue }
            let value = span.partialValue <= 4 ? at + 8 : Int(long(at + 8))
            guard value >= 0, value + Int(span.partialValue) <= bytes.count
            else { continue }
            entries[word(at)] = Entry(type: type, count: elements,
                                      valueOffset: value)
        }
        return entries
    }

    private static func typeSize(_ type: UInt16) -> Int {
        switch type {
        case 1, 2, 6, 7: return 1          // BYTE, ASCII, SBYTE, UNDEFINED
        case 3, 8: return 2                // SHORT, SSHORT
        case 4, 9, 11: return 4            // LONG, SLONG, FLOAT
        case 5, 10, 12: return 8           // RATIONAL, SRATIONAL, DOUBLE
        default: return 0
        }
    }

    /// The directory that describes the lens: whichever one carries the opcodes.
    ///
    /// The first directory of a DNG is usually a preview, with the real frame in a SubIFD, so both
    /// are looked at. Where several qualify, the full-resolution image wins — a reduced-resolution
    /// preview can carry its own copy of the opcodes fitted to a different frame.
    func lensDirectory() -> Directory? {
        var candidates: [Directory] = []
        guard let root = directory(at: firstDirectory) else { return nil }
        candidates.append(root)
        if let subs = root[Tag.subIFDs] {
            for i in 0..<min(Int(subs.count), 16) {
                let offset = subs.type == 3
                    ? Int(word(subs.valueOffset + i * 2))
                    : Int(long(subs.valueOffset + i * 4))
                if let sub = directory(at: offset) { candidates.append(sub) }
            }
        }
        let carrying = candidates.filter {
            $0[Tag.opcodeList2] != nil || $0[Tag.opcodeList3] != nil
        }
        return carrying.first { unsigned($0[Tag.newSubFileType], at: 0) == 0 }
            ?? carrying.first
    }

    /// The bytes of an UNDEFINED-typed tag.
    func undefinedBytes(_ tag: UInt16, in directory: Directory) -> [UInt8]? {
        guard let entry = directory[tag], entry.count > 0,
              entry.type == 1 || entry.type == 7 else { return nil }
        let end = entry.valueOffset + Int(entry.count)
        guard end <= bytes.count else { return nil }
        return Array(bytes[entry.valueOffset..<end])
    }

    /// One element of a SHORT, LONG or RATIONAL tag as a number.
    private func unsigned(_ entry: Entry?, at index: Int) -> Double? {
        guard let entry, index < Int(entry.count) else { return nil }
        switch entry.type {
        case 3: return Double(word(entry.valueOffset + index * 2))
        case 4: return Double(long(entry.valueOffset + index * 4))
        case 5:
            let denominator = long(entry.valueOffset + index * 8 + 4)
            guard denominator != 0 else { return nil }
            return Double(long(entry.valueOffset + index * 8)) / Double(denominator)
        default: return nil
        }
    }

    /// Returns the diagonal scale from DNG `ActiveArea` opcode coordinates to `DefaultCropSize`.
    /// Returns 1 for missing tags or off-center crops, which require an optical-center translation.
    func deliveredRadiusScale(in directory: Directory) -> Float {
        let active = (0..<4).map { unsigned(directory[Tag.activeArea], at: $0) }
        let activeWidth: Double, activeHeight: Double
        if let top = active[0], let left = active[1], let bottom = active[2],
           let right = active[3], bottom > top, right > left {
            activeHeight = bottom - top
            activeWidth = right - left
        } else {
            return 1
        }
        guard let cropWidth = unsigned(directory[Tag.defaultCropSize], at: 0),
              let cropHeight = unsigned(directory[Tag.defaultCropSize], at: 1),
              cropWidth > 0, cropHeight > 0 else { return 1 }
        if let originX = unsigned(directory[Tag.defaultCropOrigin], at: 0),
           let originY = unsigned(directory[Tag.defaultCropOrigin], at: 1) {
            let slackX = activeWidth - cropWidth - 2 * originX
            let slackY = activeHeight - cropHeight - 2 * originY
            guard abs(slackX) <= 1, abs(slackY) <= 1 else { return 1 }
        }
        let delivered = (cropWidth * cropWidth + cropHeight * cropHeight).squareRoot()
        let whole = (activeWidth * activeWidth + activeHeight * activeHeight)
            .squareRoot()
        guard whole > 0 else { return 1 }
        return Float(delivered / whole)
    }
}

/// A cursor over the opcode stream, which is big-endian by the spec regardless of the file's order.
private struct BigEndianReader {
    let bytes: [UInt8]
    var at = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func skip(_ count: Int) -> Bool {
        guard at + count <= bytes.count else { return false }
        at += count
        return true
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, at + count <= bytes.count else { return nil }
        defer { at += count }
        return Array(bytes[at..<(at + count)])
    }

    mutating func uint32() -> UInt32? {
        guard at + 4 <= bytes.count else { return nil }
        defer { at += 4 }
        return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
            | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    mutating func double() -> Double? {
        guard at + 8 <= bytes.count else { return nil }
        var pattern: UInt64 = 0
        for i in 0..<8 { pattern = pattern << 8 | UInt64(bytes[at + i]) }
        at += 8
        let value = Double(bitPattern: pattern)
        // A NaN or an infinity would poison every radius it touched, and a file offering one is not
        // one whose numbers should be trusted at all.
        return value.isFinite ? value : nil
    }
}
