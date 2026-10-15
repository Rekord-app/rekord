import Foundation

public struct MotionTrack: Sendable {
    public let samples: [PointerSample]
    /// Camera follow path. The raw pointer, resampled at 60 Hz, first passes a dead zone: the camera holds
    /// still while the cursor moves within ±`followDeadZone` of it and only pans when the cursor pushes past.
    /// The result is Gaussian-smoothed in both time directions: zero-phase, so the camera neither lags nor
    /// reacts to hand jitter, and a pure function of time, so preview seeking and export stay deterministic.
    private let follow: [Point]
    private let followStart: Double
    static let followRate = 60.0
    public static let followSigma = 0.2
    public static let followDeadZone = 0.1
    public init(samples: [PointerSample], smoothing: Double) {
        var result = samples.sorted { $0.time < $1.time }
        (follow,followStart) = Self.followPath(result)
        if smoothing > 0, result.count > 1 {
            for i in 1..<result.count {
                let dt = max(0, result[i].time-result[i-1].time)
                result[i].position = result[i-1].position.mixed(with: result[i].position, by: 1-exp(-dt/smoothing))
            }
        }
        self.samples = result
    }
    private static func followPath(_ raw: [PointerSample]) -> ([Point],Double) {
        guard let first = raw.first, let last = raw.last else { return ([],0) }
        let count = Int((last.time-first.time)*followRate)+1
        var points: [Point] = [], j = 0
        points.reserveCapacity(count)
        for i in 0..<count {
            let t = first.time+Double(i)/followRate
            while j+1 < raw.count-1, raw[j+1].time <= t { j += 1 }
            let a = raw[j], b = raw[min(j+1,raw.count-1)]
            let u = b.time > a.time ? min(1,max(0,(t-a.time)/(b.time-a.time))) : 0
            points.append(a.position.mixed(with: b.position,by: u))
        }
        var held = points
        var camera = points[0]
        for i in 0..<count {
            let d = points[i]
            if d.x-camera.x > followDeadZone { camera.x = d.x-followDeadZone } else if camera.x-d.x > followDeadZone { camera.x = d.x+followDeadZone }
            if d.y-camera.y > followDeadZone { camera.y = d.y-followDeadZone } else if camera.y-d.y > followDeadZone { camera.y = d.y+followDeadZone }
            held[i] = camera
        }
        points = held
        let radius = Int(followSigma*followRate*3)
        let weights = (0...radius).map { exp(-0.5*pow(Double($0)/(followSigma*followRate),2)) }
        var smoothed = points
        for i in 0..<count {
            var x = 0.0, y = 0.0, total = 0.0
            for k in -radius...radius {
                let p = points[min(count-1,max(0,i+k))], w = weights[abs(k)]
                x += p.x*w; y += p.y*w; total += w
            }
            smoothed[i] = Point(x/total,y/total)
        }
        return (smoothed,first.time)
    }
    /// Smoothed camera target at `time`, or nil without pointer data.
    public func followTarget(at time: Double) -> Point? {
        guard !follow.isEmpty else { return nil }
        let index = (time-followStart)*Self.followRate
        if index <= 0 { return follow[0] }
        let i = Int(index)
        if i >= follow.count-1 { return follow[follow.count-1] }
        return follow[i].mixed(with: follow[i+1],by: index-Double(i))
    }
    public func sample(at time: Double) -> PointerSample? {
        guard let first = samples.first else { return nil }
        if time <= first.time { return first }
        guard let last = samples.last, time < last.time else { return samples.last }
        var lo = 0, hi = samples.count-1
        while lo+1 < hi { let mid = (lo+hi)/2; if samples[mid].time <= time { lo = mid } else { hi = mid } }
        let a = samples[lo], b = samples[hi]
        let t = min(1, max(0, (time-a.time)/max(0.000001,b.time-a.time)))
        return PointerSample(time: time, position: a.position.mixed(with: b.position, by: t), clicked: false, visible: a.visible)
    }
}
public struct CameraState: Equatable, Sendable {
    public var scale: Double
    public var center: Point
    public init(scale: Double = 1, center: Point = .center) { self.scale = scale; self.center = center }
}
public enum Motion {
    /// One zoom per click (or run of nearby clicks). With the standard 0.4 s lead the spring is ~83 % engaged on
    /// the click itself and lands shortly after.
    public static func automaticZooms(pointer: [PointerSample], duration: Double, settings: AutoZoomSettings = .standard) -> [ZoomSegment] {
        let clicks = pointer.filter { $0.clicked && $0.visible && $0.time >= 0 && $0.time < duration }
        var result: [ZoomSegment] = []
        for click in clicks {
            let start = max(0, click.time-settings.lead), end = min(duration, click.time+settings.hold)
            guard end-start >= 0.05 else { continue }
            if let last = result.last, start <= last.end + 0.35 {
                result[result.count-1].end = max(result[result.count-1].end,end)
            } else { result.append(ZoomSegment(start: start, end: end, scale: settings.scale, focus: click.position.clamped())) }
        }
        return result
    }
    /// Spring constants of the zoom motion (critically damped, rad/s). A higher value settles faster.
    public static let zoomInStiffness = 7.5
    public static let zoomOutStiffness = 6.5
    /// Step response of a critically damped spring: velocity is continuous at the start, peaks after 1/ω
    /// and lands softly without overshoot (95 % after ≈ 4.74/ω).
    public static func spring(_ elapsed: Double,_ omega: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        let x = omega*elapsed
        return 1-(1+x)*exp(-x)
    }
    /// How far a zoom segment is engaged at `time`: springs in at `start`, springs out at `end`. A closed form of
    /// the time, so preview seeking and export are exact. A zoom that starts at 0 begins already zoomed in.
    public static func engagement(of zoom: ZoomSegment,at time: Double) -> Double {
        let enter = zoom.start <= 0 ? (time >= 0 ? 1 : 0) : spring(time-zoom.start,zoomInStiffness)
        return min(1,max(0,enter-spring(time-zoom.end,zoomOutStiffness)))
    }
    /// Spring for camera layout changes (a little quicker than zooms).
    public static let layoutStiffness = 9.0
    /// The camera layout in effect at `time` and how far it has transitioned (0 = floating overlay, 1 = fully in layout).
    /// The segment with the strongest engagement wins; transitions spring in and out like zooms.
    public static func cameraLayout(at time: Double,segments: [CameraLayoutSegment]) -> (layout: CameraLayout,amount: Double)? {
        var best: (CameraLayout,Double)?
        for segment in segments where time >= segment.start-0.001 && time <= segment.end+1.5 {
            let enter = segment.start <= 0 ? (time >= 0 ? 1 : 0) : spring(time-segment.start,layoutStiffness)
            let amount = min(1,max(0,enter-spring(time-segment.end,layoutStiffness)))
            if amount > (best?.1 ?? 0.0005) { best = (segment.layout,amount) }
        }
        return best
    }
    public static func camera(at time: Double, zooms: [ZoomSegment], pointer: MotionTrack) -> CameraState {
        var scale = 1.0, total = 0.0, x = 0.0, y = 0.0, follows = false
        for z in zooms where time >= z.start && time <= z.end+1.5 {
            let weight = engagement(of: z,at: time)
            let strength = (z.scale-1)*weight
            guard strength > 0 else { continue }
            scale = max(scale,1+strength)
            let target = z.followsCursor ? (pointer.followTarget(at: time) ?? z.focus) : z.focus
            let center = Point.center.mixed(with: target,by: weight)
            x += center.x*strength; y += center.y*strength; total += strength
            follows = follows || z.followsCursor
        }
        guard total > 0 else { return CameraState() }
        let bound = 0.5/scale
        var center = Point(x/total,y/total)
        // The smoothed path may trail a fast swipe; never let the visible cursor leave the zoomed view.
        if follows, let cursor = pointer.sample(at: time), cursor.visible {
            let limit = bound*0.84
            center.x = min(cursor.position.x+limit,max(cursor.position.x-limit,center.x))
            center.y = min(cursor.position.y+limit,max(cursor.position.y-limit,center.y))
        }
        return CameraState(scale: scale,center: Point(min(1-bound,max(bound,center.x)),min(1-bound,max(bound,center.y))))
    }
}
