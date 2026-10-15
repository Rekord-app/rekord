import Foundation
import RecorderCore

/// `--motion-report <project.rekord>`: camera steadiness on real hand movement. Applies one 2× cursor-following
/// zoom across the recording and compares the previous follow rule (80 ms causal cursor smoothing) with the
/// zero-phase camera path. Speeds are in frame widths per second of the zoomed output.
func motionReport(project directory: URL) throws {
    let project = try Project.load(from: directory)
    let zoom = ZoomSegment(start: 0,end: project.duration,scale: 2,focus: .center,followsCursor: true)
    let track = MotionTrack(samples: project.pointer,smoothing: project.style.smoothing)
    func previous(_ t: Double) -> Point {
        let bound = 0.25, p = track.sample(at: t)?.position ?? .center
        return Point(min(1-bound,max(bound,p.x)),min(1-bound,max(bound,p.y)))
    }
    func current(_ t: Double) -> Point { Motion.camera(at: t,zooms: [zoom],pointer: track).center }
    for (name,center) in [("previous",previous),("zero-phase",current)] as [(String,(Double) -> Point)] {
        var speeds: [Double] = [], accelerations: [Double] = [], outside = 0, frames = 0
        var last: Point?, lastSpeed: (Double,Double)?
        var t = 0.7
        while t < project.duration-0.7 {
            let c = center(t)
            if let last {
                let vx = (c.x-last.x)*60*2, vy = (c.y-last.y)*60*2
                speeds.append((vx*vx+vy*vy).squareRoot())
                if let lastSpeed { accelerations.append((((vx-lastSpeed.0)*(vx-lastSpeed.0)+(vy-lastSpeed.1)*(vy-lastSpeed.1)).squareRoot())*60) }
                lastSpeed = (vx,vy)
            }
            if let cursor = track.sample(at: t), cursor.visible, abs(cursor.position.x-c.x) > 0.25 || abs(cursor.position.y-c.y) > 0.25 { outside += 1 }
            last = c; frames += 1; t += 1.0/60
        }
        func p(_ values: [Double],_ q: Double) -> Double { let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count-1,Int(Double(sorted.count)*q))] }
        print(String(format: "MOTION %@: camera speed median %.2f / p95 %.2f frame widths/s · acceleration p95 %.1f / max %.1f · visible cursor outside view %.1f%% of %d frames",name,p(speeds,0.5),p(speeds,0.95),p(accelerations,0.95),accelerations.max() ?? 0,Double(outside)/Double(max(1,frames))*100,frames))
    }
}
