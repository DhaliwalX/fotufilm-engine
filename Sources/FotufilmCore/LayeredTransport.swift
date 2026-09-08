import Foundation

/// An explicitly conditional launch model. The layer stack determines where returned light
/// lands; independently supplied returned/direct ratios determine its calibrated amount.
/// Neither a cosine-power launch nor the ratios are a measurement of multiple scattering.
public struct LayeredTransport: Codable, Sendable, Equatable {
    public struct Layer: Codable, Sendable, Equatable {
        public var id: String
        public var thicknessMM: Double
        /// Either one constant or a sample on every wavelength in SpectralGrid.
        public var refractiveIndex: [Double]
        public var absorptionPerMM: [Double]

        public init(id: String, thicknessMM: Double, refractiveIndex: [Double],
                    absorptionPerMM: [Double]) {
            self.id = id; self.thicknessMM = thicknessMM
            self.refractiveIndex = refractiveIndex
            self.absorptionPerMM = absorptionPerMM
        }
    }

    public var revision: Int = 1
    public var kind: String = "conditional-launch"
    public var constructionID: String
    public var provenance: String
    public var wavelengthsNM: [Double] = SpectralGrid.wavelengths.map(Double.init)
    /// Ordered from the exposing surface to the rear surface.
    public var layers: [Layer]
    public var frontIndex: [Double]
    public var rearIndex: [Double]
    /// Reflectance of an opaque backing; its complement is absorbed. Nil uses the dielectric boundary.
    public var rearReflectance: [Double]?
    /// Capture/launch planes measured down from the exposing surface, in R,G,B order.
    public var recordDepthMM: [Double]
    public var angularExponent: [[Double]]
    /// Fraction captured on each subsequent crossing of its receiver plane.
    public var captureProbability: [[Double]]
    public var returnedToDirect: [[Double]]
    /// Independently specified compact no-return response; not added to the old emulsion MTF.
    public var coreSigmaMM: [Double]

    public init(constructionID: String, provenance: String, layers: [Layer],
                frontIndex: [Double] = [1], rearIndex: [Double] = [1],
                rearReflectance: [Double]? = nil, recordDepthMM: [Double],
                angularExponent: [[Double]], captureProbability: [[Double]],
                returnedToDirect: [[Double]], coreSigmaMM: [Double]) {
        self.constructionID = constructionID; self.provenance = provenance
        self.layers = layers; self.frontIndex = frontIndex; self.rearIndex = rearIndex
        self.rearReflectance = rearReflectance; self.recordDepthMM = recordDepthMM
        self.angularExponent = angularExponent; self.captureProbability = captureProbability
        self.returnedToDirect = returnedToDirect; self.coreSigmaMM = coreSigmaMM
    }

    public func validate() throws {
        func require(_ condition: Bool, _ text: String) throws {
            if !condition { throw TransportError.invalid(text) }
        }
        func spectrum(_ values: [Double], _ range: ClosedRange<Double>, _ name: String) throws {
            try require(values.count == 1 || values.count == SpectralGrid.count,
                        "\(name) must have one or \(SpectralGrid.count) samples")
            try require(values.allSatisfy { $0.isFinite && range.contains($0) },
                        "\(name) contains an invalid value")
        }
        try require(revision == 1 && kind == "conditional-launch", "unsupported transport revision/kind")
        try require(!constructionID.isEmpty && constructionID.utf8.count <= 128,
                    "invalid construction ID")
        try require(["illustrative", "inferred", "measured"].contains(provenance), "invalid provenance")
        try require(wavelengthsNM == SpectralGrid.wavelengths.map(Double.init), "transport wavelength grid mismatch")
        try require(!layers.isEmpty && layers.count <= 16, "expected 1...16 optical layers")
        try require(Set(layers.map(\.id)).count == layers.count, "duplicate optical layer IDs")
        for layer in layers {
            try require(!layer.id.isEmpty && layer.id.utf8.count <= 128, "invalid optical layer ID")
            try require(layer.thicknessMM.isFinite && layer.thicknessMM > 0 && layer.thicknessMM <= 2,
                        "invalid layer thickness")
            try spectrum(layer.refractiveIndex, 1...4, "refractiveIndex")
            try spectrum(layer.absorptionPerMM, 0...100_000, "absorptionPerMM")
        }
        try spectrum(frontIndex, 1...4, "frontIndex")
        try spectrum(rearIndex, 1...4, "rearIndex")
        if let rearReflectance { try spectrum(rearReflectance, 0...1, "rearReflectance") }
        let thickness = layers.reduce(0) { $0 + $1.thicknessMM }
        try require(recordDepthMM.count == 3 && recordDepthMM.allSatisfy {
            $0.isFinite && $0 > 0 && $0 < thickness
        }, "receiver planes must lie inside the stack")
        try require(coreSigmaMM.count == 3 && coreSigmaMM.allSatisfy {
            $0.isFinite && (0...0.5).contains($0)
        }, "invalid core sigma")
        for (rows, range, name) in [(angularExponent, 0.0...32.0, "angularExponent"),
                                  (captureProbability, 0.001...1.0, "captureProbability"),
                                  (returnedToDirect, 0.0...100.0, "returnedToDirect")] {
            try require(rows.count == 3, "\(name) needs three receiver rows")
            for row in rows { try spectrum(row, range, name) }
        }
    }

    static func sample(_ spectrum: [Double], _ band: Int) -> Double {
        spectrum.count == 1 ? spectrum[0] : spectrum[band]
    }
}

public enum TransportError: Error, LocalizedError {
    case invalid(String)
    case convergence(String)
    case unsupported(String)
    case backend(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .convergence(let s), .unsupported(let s), .backend(let s):
            return "Layered transport: \(s)"
        }
    }
}

/// A rotationally symmetric probability distribution represented by positive radial masses.
/// Ring nodes are quadrature, not a sixteen-direction rendering approximation.
public struct TransportRadialKernel: Sendable, Equatable {
    public let radiusMM: [Double]
    public let mass: [Double]

    public init(radiusMM: [Double], mass: [Double]) throws {
        guard !mass.isEmpty, radiusMM.count == mass.count,
              zip(radiusMM, mass).allSatisfy({ $0.isFinite && $0 >= 0 && $1.isFinite && $1 >= 0 }),
              mass.reduce(0, +).isFinite, mass.reduce(0, +) > 0 else {
            throw TransportError.invalid("invalid radial probability distribution")
        }
        let sum = mass.reduce(0, +)
        let sorted = zip(radiusMM, mass).sorted { $0.0 < $1.0 }
        self.radiusMM = sorted.map(\.0)
        self.mass = sorted.map { $0.1 / sum }
    }

    public func encircledEnergy(radiusMM radius: Double) -> Double {
        zip(radiusMM, mass).reduce(0) { $0 + ($1.0 <= radius ? $1.1 : 0) }
    }

    public func quantile(_ fraction: Double) -> Double {
        var sum = 0.0
        for (r, w) in zip(radiusMM, mass) {
            sum += w
            if sum >= fraction { return r }
        }
        return radiusMM.last ?? 0
    }

    public func edgeSpread(distanceMM x: Double) -> Double {
        if x < 0 { return 1 - edgeSpread(distanceMM: -x) }
        if x == 0 { return 0.5 }
        return zip(radiusMM, mass).reduce(0) { sum, node in
            sum + (node.0 > x ? node.1 * acos(x / node.0) / .pi : 0)
        }
    }

    static func gaussian(sigmaMM: Double, nodes: Int = 128) throws -> Self {
        guard sigmaMM > 0 else { return try Self(radiusMM: [0], mass: [1]) }
        return try Self(radiusMM: (0..<nodes).map {
            sigmaMM * sqrt(-2 * log(1 - (Double($0) + 0.5) / Double(nodes)))
        }, mass: Array(repeating: 1, count: nodes))
    }
}

public struct TransportSolveResult: Sendable {
    public let kernel: TransportRadialKernel?
    /// Power conditional on the declared launch, not incident scene power.
    public let captured: Double
    /// Capture before a rear reflection; excluded from the returned-light kernel.
    public let unreturnedCapture: Double
    public let absorbed: Double
    public let escaped: Double
    public let unresolved: Double
    public let angularSamples: Int
    public var accountingResidual: Double { abs(1 - captured - unreturnedCapture - absorbed - escaped - unresolved) }
}

public enum LayeredTransportSolver {
    /// Fresnel POWER reflectance. Refraction changes solid angle, not packet power.
    public static func fresnel(from n1: Double, to n2: Double, invariant p: Double)
        -> (s: Double, p: Double) {
        guard p < n1 else { return (1, 1) }
        if p >= n2 { return (1, 1) }
        let c1 = sqrt(max(0, 1 - (p / n1) * (p / n1)))
        let c2 = sqrt(max(0, 1 - (p / n2) * (p / n2)))
        let ds = n1 * c1 + n2 * c2, dp = n2 * c1 + n1 * c2
        return (ds > 0 ? pow((n1 * c1 - n2 * c2) / ds, 2) : 1,
                dp > 0 ? pow((n2 * c1 - n1 * c2) / dp, 2) : 1)
    }

    /// Integrates specular branches after a declared forward scattering launch at one receiver.
    /// Each receiver is a separate conditional experiment, not three claims on the same photon.
    public static func solve(_ model: LayeredTransport, receiver: Int, band: Int,
                             angularSamples: Int = 512, residualTolerance: Double = 1e-7)
        throws -> TransportSolveResult {
        try model.validate()
        guard (0..<3).contains(receiver), (0..<SpectralGrid.count).contains(band),
              (32...8192).contains(angularSamples), residualTolerance.isFinite,
              residualTolerance > 0 && residualTolerance <= 1e-3 else {
            throw TransportError.invalid("invalid solve request")
        }
        let source = model.recordDepthMM[receiver]
        var positions = [0.0]
        for layer in model.layers { positions.append(positions.last! + layer.thicknessMM) }
        // Insert an index-matched virtual capture plane; it neither refracts nor reflects.
        var edges = positions
        if !edges.contains(source) { edges.append(source) }
        edges.sort()
        let sourceEdge = edges.firstIndex(of: source)!
        let count = edges.count - 1
        var indices = [Double](), absorption = [Double]()
        for j in 0..<count {
            let center = (edges[j] + edges[j+1]) / 2
            let l = (0..<model.layers.count).first { center < positions[$0+1] }!
            indices.append(LayeredTransport.sample(model.layers[l].refractiveIndex, band))
            absorption.append(LayeredTransport.sample(model.layers[l].absorptionPerMM, band))
        }
        let n0 = indices[sourceEdge]
        let q = LayeredTransport.sample(model.angularExponent[receiver], band)
        let capture = LayeredTransport.sample(model.captureProbability[receiver], band)
        struct Packet {
            var layer: Int; var down: Bool; var r: Double; var s: Double; var p: Double
            var returned: Bool; var events: Int; var visits: [UInt16]
        }
        struct PathKey: Hashable {
            let layer: Int; let down: Bool; let returned: Bool; let visits: [UInt16]
        }
        var radii = [Double](), masses = [Double]()
        var captured = 0.0, unreturnedCapture = 0.0, absorbed = 0.0, escaped = 0.0, unresolved = 0.0
        // Equal probability strata in u=cos(theta) avoid noisy normalization of the launch.
        for angle in 0..<angularSamples {
            let u = pow((Double(angle) + 0.5) / Double(angularSamples), 1 / (q + 1))
            let invariant = n0 * sqrt(max(0, 1 - u * u))
            let weight = 0.5 / Double(angularSamples)
            var queue = [Packet(layer: sourceEdge, down: true, r: 0, s: weight, p: weight,
                                returned: false, events: 0, visits: Array(repeating: 0, count: count))]
            while !queue.isEmpty {
                var nextQueue = [Packet](), lookup = [PathKey: Int]()
                // Paths with the same segment traversal counts have exactly the same lateral
                // displacement. Combine their power before further branching, without radial bins.
                func enqueue(_ packet: Packet) {
                    let key = PathKey(layer: packet.layer, down: packet.down,
                                      returned: packet.returned, visits: packet.visits)
                    if let i = lookup[key] {
                        nextQueue[i].s += packet.s; nextQueue[i].p += packet.p
                    } else { lookup[key] = nextQueue.count; nextQueue.append(packet) }
                }
                for var packet in queue {
                    let power = packet.s + packet.p
                    if power < residualTolerance * 1e-4 / Double(angularSamples) || packet.events >= 512 {
                        unresolved += power; continue
                    }
                    guard queue.count < 200_000 else { throw TransportError.convergence("too many optical branches") }
                    let j = packet.layer, n = indices[j]
                    packet.visits[j] += 1
                    let cosine = sqrt(max(0, 1 - pow(invariant / n, 2)))
                    guard cosine > 0 else { throw TransportError.convergence("invalid transmitted angle") }
                    let depth = edges[j+1] - edges[j]
                    packet.r += depth * invariant / n / cosine
                    let survival = exp(-absorption[j] * depth / cosine)
                    absorbed += power * (1 - survival)
                    packet.s *= survival; packet.p *= survival
                    packet.events += 1
                    let edge = packet.down ? j + 1 : j
                    if edge == sourceEdge {
                        let scored = (packet.s + packet.p) * capture
                        if packet.returned && scored > 0 {
                            radii.append(packet.r); masses.append(scored); captured += scored
                        } else { unreturnedCapture += scored }
                        packet.s *= 1 - capture; packet.p *= 1 - capture
                    }
                    let next = packet.down ? j + 1 : j - 1
                    let exterior = next < 0 || next >= count
                    let nextIndex = next < 0 ? LayeredTransport.sample(model.frontIndex, band)
                        : (next >= count ? LayeredTransport.sample(model.rearIndex, band) : indices[next])
                    var reflectance = fresnel(from: n, to: nextIndex, invariant: invariant)
                    if next >= count, let override = model.rearReflectance {
                        let value = LayeredTransport.sample(override, band)
                        reflectance = (value, value)
                    }
                    let reflectedS = packet.s * reflectance.s, reflectedP = packet.p * reflectance.p
                    let transmittedS = packet.s - reflectedS, transmittedP = packet.p - reflectedP
                    if next >= count && model.rearReflectance != nil {
                        // An effective opaque backing reflects this fraction and absorbs the rest.
                        absorbed += transmittedS + transmittedP
                    } else if exterior { escaped += transmittedS + transmittedP }
                    else if transmittedS + transmittedP > 0 {
                        enqueue(Packet(layer: next, down: packet.down, r: packet.r,
                                            s: transmittedS, p: transmittedP, returned: packet.returned,
                                            events: packet.events, visits: packet.visits))
                    }
                    if reflectedS + reflectedP > 0 {
                        enqueue(Packet(layer: j, down: !packet.down, r: packet.r,
                                            s: reflectedS, p: reflectedP,
                                            returned: packet.returned || next >= count,
                                            events: packet.events, visits: packet.visits))
                    }
                }
                queue = nextQueue
            }
        }
        guard unresolved <= residualTolerance else {
            throw TransportError.convergence("unresolved conditional launch power \(unresolved)")
        }
        let kernel = captured > 0 ? try TransportRadialKernel(radiusMM: radii, mass: masses) : nil
        return TransportSolveResult(kernel: kernel, captured: captured, unreturnedCapture: unreturnedCapture, absorbed: absorbed,
                                    escaped: escaped, unresolved: unresolved, angularSamples: angularSamples)
    }
}
