import Foundation

/// A detached Curves settings value. Owned named tags keep facade enum
/// ordinals and native identities out of the model; every channel preserves
/// the whole native state — the HDR bypass `identity` flag, every point with
/// its kind, and all 256 samples. A smooth channel renders its sample table,
/// and that table can differ from what its point list would generate, so
/// both representations are kept for every kind and an edit-curve patch
/// cannot be substituted for it.
struct RecorderCurvesValue: Equatable {
    /// Glims' owned transfer-curve tags, not native enum ordinals.
    enum TRC: String { case linear, nonlinear, perceptual }
    /// Glims' owned curve-kind tags, not native enum ordinals.
    enum CurveKind: String { case smooth, free }
    /// Glims' owned point-kind tags, not native enum ordinals.
    enum PointKind: String { case smooth, corner }
    struct Point: Equatable {
        let x: Double
        let y: Double
        let kind: PointKind
    }
    /// One named channel. `identity` is the stored HDR bypass behavior and
    /// is never derived from `points`/`samples`; both representations
    /// roundtrip exactly for every `kind`.
    struct Channel: Equatable {
        let kind: CurveKind
        let identity: Bool
        let points: [Point]
        let samples: [Double]

        /// Enforces the same contract as the frontend: finite 0...1 points
        /// in nondecreasing x order, at most 65,536 of them, and exactly 256
        /// finite 0...1 samples.
        func validated() throws -> Channel {
            guard points.count <= 65_536 else {
                throw RecorderFileError.invalid("A recorded Curves channel has too many points.")
            }
            for point in points {
                guard point.x.isFinite, point.y.isFinite,
                      (0...1).contains(point.x), (0...1).contains(point.y) else {
                    throw RecorderFileError.invalid("A recorded Curves point is not a finite 0...1 value.")
                }
            }
            for (previous, next) in zip(points, points.dropFirst()) where previous.x > next.x {
                throw RecorderFileError.invalid("A recorded Curves point sequence is out of order.")
            }
            guard samples.count == 256 else {
                throw RecorderFileError.invalid("A recorded Curves channel must carry exactly 256 samples.")
            }
            guard samples.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw RecorderFileError.invalid("A recorded Curves sample is not a finite 0...1 value.")
            }
            return self
        }
    }

    let trc: TRC
    let value: Channel
    let red: Channel
    let green: Channel
    let blue: Channel
    let alpha: Channel

    /// Caller-built values are not trusted: `settings()` and the file codec
    /// revalidate every field before use.
    init(trc: TRC, value: Channel, red: Channel, green: Channel, blue: Channel, alpha: Channel) {
        self.trc = trc
        self.value = value
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Bridge in: validates and detaches committed facade settings. An
    /// unknown transfer curve or any invalid channel state refuses instead
    /// of producing a partial value.
    init(_ settings: EngineSession.CurvesSettings) throws {
        switch settings.trc {
        case .linear: trc = .linear
        case .nonlinear: trc = .nonlinear
        case .perceptual: trc = .perceptual
        case .unknown: throw RecorderFileError.invalid("A recorded Curves transfer curve is unknown.")
        }
        func channel(_ state: EngineSession.CurveState) throws -> Channel {
            let kind: CurveKind
            switch state.kind {
            case .smooth: kind = .smooth
            case .free: kind = .free
            }
            let points = try state.points.map { point -> Point in
                let kind: PointKind
                switch point.kind {
                case .smooth: kind = .smooth
                case .corner: kind = .corner
                }
                return Point(x: point.x, y: point.y, kind: kind)
            }
            return try Channel(kind: kind, identity: state.identity,
                               points: points, samples: state.samples).validated()
        }
        value = try channel(settings.value)
        red = try channel(settings.red)
        green = try channel(settings.green)
        blue = try channel(settings.blue)
        alpha = try channel(settings.alpha)
    }

    /// Bridge out: revalidates every field a caller could have built by hand
    /// before restoring exact facade settings.
    func settings() throws -> EngineSession.CurvesSettings {
        let trc: EngineSession.ColorTRC
        switch self.trc {
        case .linear: trc = .linear
        case .nonlinear: trc = .nonlinear
        case .perceptual: trc = .perceptual
        }
        func state(_ channel: Channel) throws -> EngineSession.CurveState {
            let channel = try channel.validated()
            let kind: EngineSession.CurveKind
            switch channel.kind {
            case .smooth: kind = .smooth
            case .free: kind = .free
            }
            let points = channel.points.map { point -> EngineSession.CurvePoint in
                let kind: EngineSession.CurvePointKind
                switch point.kind {
                case .smooth: kind = .smooth
                case .corner: kind = .corner
                }
                return EngineSession.CurvePoint(x: point.x, y: point.y, kind: kind)
            }
            return EngineSession.CurveState(kind: kind, identity: channel.identity,
                                            points: points, samples: channel.samples)
        }
        return EngineSession.CurvesSettings(trc: trc, value: try state(value),
            red: try state(red), green: try state(green),
            blue: try state(blue), alpha: try state(alpha))
    }
}
