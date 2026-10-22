import Foundation

/// A 10-bit Cineon DPX file (SMPTE 268M-2003, version 2.0): one RGB image element whose transfer
/// and colorimetry are printing density, packed three components to a big-endian 32-bit word
/// (method A, two pad bits at the bottom). It is what a film scanner hands a grading suite, and
/// what DaVinci Resolve reads as Cineon Film Log.
public enum CineonDPX {
    /// Header bytes before the image data: the 1664-byte generic header (file, image and
    /// orientation) and the 384-byte industry header (film and television).
    static let imageOffset = 2048
    /// The MIME type hosts name the format by.
    public static let mimeType = "image/x-dpx"

    /// Optional film and frame details for the industry header.
    public struct Film: Sendable, Equatable {
        /// Frame rate of the original, frames per second.
        public var frameRate: Float?
        /// Format description, for example "Super 35".
        public var format: String?
        /// The stock, written as the frame identification.
        public var stock: String?

        public init(frameRate: Float? = nil, format: String? = nil, stock: String? = nil) {
            self.frameRate = frameRate
            self.format = format
            self.stock = stock
        }
    }

    /// Encodes normalised Cineon signals (`CineonLog`, code value / 1023) as a DPX file.
    /// `pixels` is interleaved with `stride` floats per pixel, red, green and blue first.
    public static func encode(signals pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                              stride: Int = 4, film: Film = Film(),
                              creator: String = "Fotufilm", date: Date = Date()) -> Data {
        precondition(width > 0 && height > 0 && stride >= 3)
        precondition(pixels.count >= width * height * stride)
        let imageBytes = width * height * 4
        var data = Data(count: imageOffset + imageBytes)
        data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            func u32(_ value: UInt32, at offset: Int) {
                bytes[offset] = UInt8(value >> 24); bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
                bytes[offset + 2] = UInt8((value >> 8) & 0xFF); bytes[offset + 3] = UInt8(value & 0xFF)
            }
            func u16(_ value: UInt16, at offset: Int) {
                bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 0xFF)
            }
            func f32(_ value: Float, at offset: Int) { u32(value.bitPattern, at: offset) }
            func text(_ value: String, at offset: Int, length: Int) {
                for (i, byte) in value.utf8.prefix(length - 1).enumerated() { bytes[offset + i] = byte }
            }
            // Undefined numeric fields are all ones, as the standard asks; text stays zeroed.
            func undefined(_ range: Range<Int>) { for i in range { bytes[i] = 0xFF } }

            // File information header, 0..<768.
            u32(0x5344_5058, at: 0)  // "SDPX": big-endian
            u32(UInt32(imageOffset), at: 4)
            text("V2.0", at: 8, length: 8)
            u32(UInt32(imageOffset + imageBytes), at: 16)
            u32(1, at: 20)  // ditto key: a new frame
            u32(1664, at: 24)  // generic header: file, image and orientation
            u32(384, at: 28)  // industry header: film and television
            u32(0, at: 32)  // no user data
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd:HH:mm:ssZZZ"
            text(formatter.string(from: date), at: 136, length: 24)
            text(creator, at: 160, length: 100)
            undefined(660..<664)  // no encryption key

            // Image information header, 768..<1408.
            u16(0, at: 768)  // left to right, top to bottom
            u16(1, at: 770)
            u32(UInt32(width), at: 772)
            u32(UInt32(height), at: 776)
            let element = 780
            u32(0, at: element)  // unsigned
            u32(0, at: element + 4)  // reference low data code
            f32(0, at: element + 8)  // ... at zero density above the scale's origin
            u32(1023, at: element + 12)  // reference high data code
            f32(1023 * CineonLog.densityPerCodeValue, at: element + 16)
            bytes[element + 20] = 50  // RGB
            bytes[element + 21] = 1  // transfer: printing density
            bytes[element + 22] = 1  // colorimetric: printing density
            bytes[element + 23] = 10
            u16(1, at: element + 24)  // filled, method A
            u16(0, at: element + 26)  // no run-length encoding
            u32(UInt32(imageOffset), at: element + 28)
            u32(0, at: element + 32)
            u32(0, at: element + 36)
            text("Cineon log, printing density", at: element + 40, length: 32)
            // The seven unused element slots.
            undefined((element + 72)..<(element + 8 * 72))

            // Orientation header, 1408..<1664: no offsets, centres or source sizes are known.
            undefined(1408..<1432)
            undefined(1620..<1636)  // border validity and pixel aspect ratio
            u32(1, at: 1628); u32(1, at: 1632)  // square pixels
            undefined(1636..<1644)  // scanned size

            // Film information header, 1664..<1920.
            if let format = film.format { text(format, at: 1680, length: 32) }
            undefined(1712..<1724)  // frame position, sequence length, held count
            f32(film.frameRate ?? Float(bitPattern: 0xFFFF_FFFF), at: 1724)
            undefined(1728..<1732)  // shutter angle
            if let stock = film.stock { text(stock, at: 1732, length: 32) }

            // Television information header, 1920..<2048: nothing applies to a film scan.
            undefined(1920..<1976)

            // Image data: R, G and B in bits 31-22, 21-12 and 11-2 of each word.
            for y in 0..<height {
                for x in 0..<width {
                    let source = (y * width + x) * stride
                    let r = UInt32(CineonLog.codeValue(signal: pixels[source]))
                    let g = UInt32(CineonLog.codeValue(signal: pixels[source + 1]))
                    let b = UInt32(CineonLog.codeValue(signal: pixels[source + 2]))
                    u32(r << 22 | g << 12 | b << 2, at: imageOffset + (y * width + x) * 4)
                }
            }
        }
        return data
    }
}
