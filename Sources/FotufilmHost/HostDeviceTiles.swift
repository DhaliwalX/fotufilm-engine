import Foundation

/// A frame developed on a device that may not hold it: whole when it fits, otherwise a tile at a
/// time, each read with the film's whole reach around it (`apron`) and placed in frame
/// coordinates, so every pixel comes out as the whole frame's would. Tiles shrink until the
/// device holds one. Linux's developer drives its CUDA and Vulkan entry points through it.
enum HostDeviceTiles {
    /// The smallest tile worth cutting, in delivered pixels a side, as on the Mac.
    static let minimumTile = 256

    /// One develop on the device: `input` is `columns` × `rows` interleaved RGBA whose first pixel
    /// sits at `origin` in the frame; `output` receives the window of it the tile delivers,
    /// packed. Returns the engine's status.
    typealias Develop = (_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>,
                         _ columns: Int, _ rows: Int,
                         _ window: (x: Int, columns: Int, y: Int, rows: Int),
                         _ origin: (x: Int, y: Int)) -> Int32

    /// The delivered size of a tile whose input, apron included, reads about `budget` pixels;
    /// the whole frame when it is no larger.
    static func tile(width: Int, height: Int, apron: Int, budget: Int) -> (columns: Int, rows: Int) {
        guard width * height > budget else { return (width, height) }
        let side = Int(Double(max(1, budget)).squareRoot()) - 2 * apron
        return (min(width, max(minimumTile, side)), min(height, max(minimumTile, side)))
    }

    /// Develops interleaved RGBA `input` into `output`, `channels` floats a pixel, reading at most
    /// `budget` pixels a develop to start with. A develop that fails `isOutOfMemory` is reported
    /// to `refused` with the pixels it read, and the frame starts again in tiles half that
    /// size; any other status ends it.
    static func develop(_ input: [Float], width: Int, height: Int, channels: Int, apron: Int,
                        budget: Int, isOutOfMemory: (Int32) -> Bool, refused: (Int) -> Void,
                        into output: inout [Float], develop: Develop) -> Int32 {
        var budget = budget
        while true {
            let tile = tile(width: width, height: height, apron: apron, budget: budget)
            var failedPixels = 0
            let status = developTiles(input, width: width, height: height, channels: channels,
                                      tile: tile, apron: apron, into: &output,
                                      failedPixels: &failedPixels, develop: develop)
            guard isOutOfMemory(status) else { return status }
            refused(failedPixels)
            if tile.columns <= minimumTile && tile.rows <= minimumTile { return status }
            budget = failedPixels / 2
        }
    }

    /// `input` developed a tile of `tile` delivered pixels at a time; `failedPixels` is what a
    /// failing develop read.
    private static func developTiles(_ input: [Float], width: Int, height: Int, channels: Int,
                                     tile: (columns: Int, rows: Int), apron: Int,
                                     into output: inout [Float], failedPixels: inout Int,
                                     develop: Develop) -> Int32 {
        if tile.columns >= width && tile.rows >= height {
            let status = input.withUnsafeBufferPointer { input in
                output.withUnsafeMutableBufferPointer { output in
                    develop(input.baseAddress!, output.baseAddress!, width, height,
                            (0, width, 0, height), (0, 0))
                }
            }
            if status != 0 { failedPixels = width * height }
            return status
        }
        var piece = [Float](), result = [Float]()
        for top in stride(from: 0, to: height, by: tile.rows) {
            for left in stride(from: 0, to: width, by: tile.columns) {
                let bottom = min(height, top + tile.rows), right = min(width, left + tile.columns)
                // What the tile reads: its pixels and the apron around them, inside the frame.
                let from = max(0, top - apron), to = min(height, bottom + apron)
                let first = max(0, left - apron), last = min(width, right + apron)
                let columns = last - first, rows = to - from
                piece.removeAll(keepingCapacity: true)
                for y in from..<to {
                    let start = (y * width + first) * 4
                    piece.append(contentsOf: input[start..<start + columns * 4])
                }
                let delivered = (right - left) * channels
                result = [Float](repeating: 0, count: delivered * (bottom - top))
                let status = piece.withUnsafeBufferPointer { piece in
                    result.withUnsafeMutableBufferPointer { result in
                        develop(piece.baseAddress!, result.baseAddress!, columns, rows,
                                (left - first, right - left, top - from, bottom - top),
                                (first, from))
                    }
                }
                guard status == 0 else {
                    failedPixels = columns * rows
                    return status
                }
                for y in top..<bottom {
                    let start = (y * width + left) * channels, row = (y - top) * delivered
                    output.replaceSubrange(start..<start + delivered,
                                           with: result[row..<row + delivered])
                }
            }
        }
        return 0
    }
}
