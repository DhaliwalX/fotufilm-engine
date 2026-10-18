import XCTest
@testable import FotufilmHost

/// The tiles a device develops a frame in, against a stand-in device: each output pixel is the
/// sum of the input within `reach` of it, tagged with its frame coordinates, so a tile read in
/// the wrong place, with too little apron, or written back to the wrong pixels shows.
final class HostDeviceTilesTests: XCTestCase {
    private let reach = 3

    private func device(channels: Int, capacity: Int = .max) -> HostDeviceTiles.Develop {
        let reach = reach
        return { input, output, columns, rows, window, origin in
            guard columns * rows <= capacity else { return -11 }
            for y in window.y..<window.y + window.rows {
                for x in window.x..<window.x + window.columns {
                    var sum: Float = 0
                    for dy in -reach...reach {
                        for dx in -reach...reach {
                            let sx = x + dx, sy = y + dy
                            guard sx >= 0, sx < columns, sy >= 0, sy < rows else { continue }
                            sum += input[(sy * columns + sx) * 4]
                        }
                    }
                    let o = ((y - window.y) * window.columns + (x - window.x)) * channels
                    output[o] = sum
                    output[o + 1] = Float(origin.x + x)
                    output[o + 2] = Float(origin.y + y)
                    if channels == 4 { output[o + 3] = 1 }
                }
            }
            return 0
        }
    }

    private func frame(width: Int, height: Int) -> [Float] {
        (0..<(width * height * 4)).map { Float(($0 * 7919) % 1013) / 1013 }
    }

    private func develop(_ input: [Float], width: Int, height: Int, channels: Int, budget: Int,
                         capacity: Int = .max, refused: inout [Int]) -> (Int32, [Float]) {
        var output = [Float](repeating: -1, count: width * height * channels)
        var seen = [Int]()
        let status = HostDeviceTiles.develop(
            input, width: width, height: height, channels: channels, apron: reach,
            budget: budget, isOutOfMemory: { $0 == -11 }, refused: { seen.append($0) },
            into: &output, develop: device(channels: channels, capacity: capacity))
        refused = seen
        return (status, output)
    }

    func testTilesDeliverWhatTheWholeFrameDoes() {
        let (width, height) = (700, 530)
        let input = frame(width: width, height: height)
        for channels in [3, 4] {
            var refused = [Int]()
            let (wholeStatus, whole) = develop(input, width: width, height: height,
                                               channels: channels, budget: .max,
                                               refused: &refused)
            XCTAssertEqual(wholeStatus, 0)
            // Tiles of 256 delivered pixels a side: a ragged last row and column of tiles.
            let (status, tiled) = develop(input, width: width, height: height,
                                          channels: channels, budget: 300 * 300,
                                          refused: &refused)
            XCTAssertEqual(status, 0)
            XCTAssertEqual(tiled, whole, "\(channels) channels")
            XCTAssertTrue(refused.isEmpty)
        }
    }

    func testShrinksUntilTheDeviceHoldsATile() {
        let (width, height) = (900, 600)
        let input = frame(width: width, height: height)
        var refused = [Int]()
        let (_, whole) = develop(input, width: width, height: height, channels: 4,
                                 budget: .max, refused: &refused)
        let (status, tiled) = develop(input, width: width, height: height, channels: 4,
                                      budget: .max, capacity: 200_000, refused: &refused)
        XCTAssertEqual(status, 0)
        XCTAssertEqual(tiled, whole)
        XCTAssertEqual(refused.first, width * height)
        XCTAssertLessThanOrEqual(refused.count, 3)
    }

    func testGivesUpWhenNoTileFits() {
        let (width, height) = (600, 600)
        var refused = [Int]()
        let (status, _) = develop(frame(width: width, height: height), width: width,
                                  height: height, channels: 4, budget: .max, capacity: 1000,
                                  refused: &refused)
        XCTAssertEqual(status, -11)
        XCTAssertFalse(refused.isEmpty)
    }

    func testTileShape() {
        XCTAssertTrue(HostDeviceTiles.tile(width: 100, height: 80, apron: 10, budget: 8000)
                      == (100, 80))
        let tile = HostDeviceTiles.tile(width: 10_000, height: 8000, apron: 100,
                                        budget: 4_000_000)
        XCTAssertTrue(tile == (1800, 1800))
        // An apron wider than the budget allows still cuts the smallest tile.
        XCTAssertTrue(HostDeviceTiles.tile(width: 10_000, height: 8000, apron: 2000,
                                           budget: 4_000_000) == (256, 256))
    }
}
