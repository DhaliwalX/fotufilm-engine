@testable import FotufilmCore

enum TestStocks {
    static let negative = FilmStock(
        name: "Test Negative 400",
        sensitivity: [
            [0.92, 0.08, 0.00],
            [0.20, 0.73, 0.07],
            [0.00, 0.02, 0.98],
        ],
        spectralProfile: .color(peaksNM: [650, 550, 450], dyeFamily: .kodakNegative),
        curves: [
            CharacteristicCurve(dMin: 0.20, gamma: 0.60, toe: -1.20, toeWidth: 0.24, shoulder: 4.20, shoulderWidth: 1.20),
            CharacteristicCurve(dMin: 0.62, gamma: 0.62, toe: -1.22, toeWidth: 0.22, shoulder: 4.00, shoulderWidth: 1.25),
            CharacteristicCurve(dMin: 0.86, gamma: 0.64, toe: -1.26, toeWidth: 0.20, shoulder: 3.90, shoulderWidth: 1.30),
        ],
        emulsionDiffusionMM: [0.0040, 0.0030, 0.0024],
        couplerInhibition: [
            [0.08, 0.20, 0.06],
            [0.22, 0.08, 0.18],
            [0.06, 0.24, 0.08],
        ],
        couplerReleaseGamma: [1.8, 1.8, 1.8],
        couplerDiffusionMM: 0.080,
        adjacencyStrength: 0.12,
        adjacencyRadiusMM: 0.030,
        grainStrength: 0.010,
        grainSizeMM: 0.005,
        grainLayerWeights: [0.7, 1.0, 1.35],
        halationStrength: [0.050, 0.020, 0.008],
        paperCurve: CharacteristicCurve(dMin: 0.07, gamma: 2.60, toe: -0.52, toeWidth: 0.16, shoulder: 0.42, shoulderWidth: 0.14))

    static let reversal = FilmStock(
        name: "Test Reversal 64",
        sensitivity: [
            [0.90, 0.10, 0.00],
            [0.16, 0.76, 0.08],
            [0.00, 0.05, 0.95],
        ],
        spectralProfile: .color(peaksNM: [640, 545, 445], dyeFamily: .kodachrome),
        curves: [
            CharacteristicCurve(dMin: 0.10, gamma: 3.00, toe: -1.00, toeWidth: 0.21, shoulder: 0.22, shoulderWidth: 0.40),
            CharacteristicCurve(dMin: 0.10, gamma: 3.05, toe: -1.02, toeWidth: 0.19, shoulder: 0.12, shoulderWidth: 0.42),
            CharacteristicCurve(dMin: 0.10, gamma: 3.20, toe: -1.06, toeWidth: 0.22, shoulder: -0.10, shoulderWidth: 0.48),
        ],
        emulsionDiffusionMM: [0.0030, 0.0024, 0.0020],
        couplerInhibition: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
        couplerDiffusionMM: 0,
        adjacencyStrength: 0.10,
        adjacencyRadiusMM: 0.025,
        grainStrength: 0.010,
        grainSizeMM: 0.004,
        grainLayerWeights: [0.8, 1.0, 1.20],
        halationStrength: [0.030, 0.014, 0.006],
        paperCurve: CharacteristicCurve(dMin: 0.07, gamma: 2.60, toe: -0.52, toeWidth: 0.16, shoulder: 0.42, shoulderWidth: 0.14),
        isReversal: true)

    static let monochrome = FilmStock(
        name: "Test Monochrome 400",
        sensitivity: [
            [0.30, 0.33, 0.37],
            [0.30, 0.33, 0.37],
            [0.30, 0.33, 0.37],
        ],
        spectralProfile: .monochrome(rgbWeights: [0.30, 0.33, 0.37]),
        curves: [
            CharacteristicCurve(dMin: 0.10, gamma: 0.62, toe: -1.00, toeWidth: 0.30, shoulder: 2.20, shoulderWidth: 0.30),
            CharacteristicCurve(dMin: 0.10, gamma: 0.62, toe: -1.00, toeWidth: 0.30, shoulder: 2.20, shoulderWidth: 0.30),
            CharacteristicCurve(dMin: 0.10, gamma: 0.62, toe: -1.00, toeWidth: 0.30, shoulder: 2.20, shoulderWidth: 0.30),
        ],
        emulsionDiffusionMM: [0.0025, 0.0025, 0.0025],
        couplerInhibition: [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
        couplerDiffusionMM: 0,
        adjacencyStrength: 0.15,
        adjacencyRadiusMM: 0.030,
        grainStrength: 0.014,
        grainSizeMM: 0.006,
        grainLayerWeights: [1, 1, 1],
        halationStrength: [0.025, 0.025, 0.025],
        paperCurve: CharacteristicCurve(dMin: 0.05, gamma: 2.90, toe: -0.48, toeWidth: 0.15, shoulder: 0.40, shoulderWidth: 0.13),
        isMonochrome: true)

    static let remjetBacked: FilmStock = {
        var stock = negative
        stock.name = "Test Remjet Negative 250"
        stock.halationStrength = [0.010, 0.004, 0.0015]
        return stock
    }()

    static let donor = DonorCaptureLayer(
        name: "Synthetic donor", sensitivity: negative.spectralProfile.layerSensitivity[1],
        curve: negative.curves[1], inhibition: [0.4, 0, 0], releaseGamma: 1.2)

    static let all: [FilmStock] = [negative, reversal, monochrome]
}
