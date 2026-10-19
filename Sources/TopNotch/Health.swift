import AppKit
import SwiftUI

// MARK: - Reminders

struct Routine: Codable, Identifiable, Equatable {
    let id: String
    var name: String, icon: String, tip: String
    var every: Int   // minutes between reminders
    var on = true
}

/// Gentle health reminders: says it, then gets out of the way. No tracking, no buttons.
@Observable final class Coach {
    var routines: [Routine] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(routines), forKey: "reminders") }
    }
    var pausedUntil: Date?

    @ObservationIgnored var last: [String: Date]   // when each reminder last showed
    @ObservationIgnored var onDue: ((Routine) -> Void)?
    @ObservationIgnored var canInterrupt: () -> Bool = { true }

    static let defaults = [
        Routine(id: "blink", name: "Blink break", icon: "eye", tip: "look far away & blink slowly", every: 20),
        Routine(id: "neck", name: "Posture", icon: "figure.mind.and.body", tip: "sit tall, slow neck tilts", every: 40),
        Routine(id: "squeeze", name: "Hands", icon: "hand.raised.fingers.spread", tip: "squeeze fists, spread fingers", every: 45),
        Routine(id: "stand", name: "Stand up", icon: "figure.stand", tip: "stand and reach high", every: 60),
        Routine(id: "water", name: "Water", icon: "drop.fill", tip: "drink a glass of water", every: 60),
        Routine(id: "breathe", name: "Breathe", icon: "wind", tip: "in 4 · hold 4 · out 4 · hold 4", every: 90),
    ]

    init() {
        UserDefaults.standard.removeObject(forKey: "routines")   // v1.3 tracker data, no longer used
        UserDefaults.standard.removeObject(forKey: "healthLog")
        let saved = UserDefaults.standard.data(forKey: "reminders").flatMap { try? JSONDecoder().decode([Routine].self, from: $0) }
        routines = saved ?? Self.defaults
        last = Dictionary(uniqueKeysWithValues: (saved ?? Self.defaults).map { ($0.id, Date()) })
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Most overdue enabled reminder at `now`, if any is due.
    static func next(_ rs: [Routine], last: [String: Date], now: Date) -> Routine? {
        rs.filter(\.on)
            .map { r in (r, now.timeIntervalSince(last[r.id] ?? now) - Double(r.every * 60)) }
            .filter { $0.1 >= 0 }
            .max { $0.1 < $1.1 }?.0
    }

    var paused: Bool { (pausedUntil ?? .distantPast) > Date() }
    func nextIn(_ r: Routine) -> Double { Double(r.every * 60) - Date().timeIntervalSince(last[r.id] ?? Date()) }
    var upcoming: Routine? { routines.filter(\.on).min { nextIn($0) < nextIn($1) } }

    private func tick() {
        // 5 min without touching the Mac = you were already away from the screen
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 300 { for r in routines { last[r.id] = Date() }; return }
        guard !paused, canInterrupt(), let r = Self.next(routines, last: last, now: Date()) else { return }
        remind(r)
    }

    func remind(_ r: Routine) {
        last[r.id] = Date()
        onDue?(r)
    }

    func test() {
        if let r = upcoming { remind(r) }
    }

    func setEvery(_ r: Routine, _ m: Int) {
        guard let i = routines.firstIndex(of: r) else { return }
        routines[i].every = min(240, max(5, m))
    }
    func toggle(_ r: Routine) {
        guard let i = routines.firstIndex(of: r) else { return }
        routines[i].on.toggle()
        last[r.id] = Date()
    }
}

// MARK: - The kitten

/// Hand-drawn ginger kitten: big sparkly eyes, pink nose, whiskers, swishing tail.
struct Cat: View {
    var size: CGFloat = 64
    var wave = false   // paw up, saying hi

    static let fur = Color(red: 0.97, green: 0.64, blue: 0.32)
    static let stripe = Color(red: 0.84, green: 0.43, blue: 0.16)
    static let cream = Color(red: 1.0, green: 0.94, blue: 0.84)
    static let pink = Color(red: 1.0, green: 0.60, blue: 0.67)
    static let ink = Color(red: 0.24, green: 0.14, blue: 0.10)

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, sz in
                ctx.scaleBy(x: sz.width / 100, y: sz.height / 100)
                Self.draw(&ctx, t: tl.date.timeIntervalSinceReferenceDate, wave: wave)
            }
        }
        .frame(width: size, height: size)
    }

    static func draw(_ ctx: inout GraphicsContext, t: Double, wave: Bool) {
        func dot(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        func line(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: Double) {
            var p = Path()
            p.move(to: a)
            p.addLine(to: b)
            ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        func tri(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Path {
            var p = Path()
            p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.closeSubpath()
            return p
        }
        let swish = sin(t * 2.4)

        // tail, swishing
        var tail = Path()
        tail.move(to: CGPoint(x: 64, y: 82))
        tail.addCurve(to: CGPoint(x: 84 + 5 * swish, y: 48), control1: CGPoint(x: 90, y: 86), control2: CGPoint(x: 92 + 4 * swish, y: 64))
        ctx.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 7, lineCap: .round))
        ctx.fill(dot(84 + 5 * swish, 48, 3.6), with: .color(stripe))

        // body, belly, paws
        ctx.fill(Path(ellipseIn: CGRect(x: 30, y: 52, width: 40, height: 38)), with: .color(fur))
        ctx.fill(Path(ellipseIn: CGRect(x: 40, y: 60, width: 20, height: 26)), with: .color(cream))
        ctx.fill(Path(ellipseIn: CGRect(x: 35, y: 83, width: 13, height: 8)), with: .color(cream))
        if !wave { ctx.fill(Path(ellipseIn: CGRect(x: 52, y: 83, width: 13, height: 8)), with: .color(cream)) }

        // ears
        ctx.fill(tri(CGPoint(x: 25, y: 30), CGPoint(x: 29, y: 4), CGPoint(x: 46, y: 18)), with: .color(fur))
        ctx.fill(tri(CGPoint(x: 75, y: 30), CGPoint(x: 71, y: 4), CGPoint(x: 54, y: 18)), with: .color(fur))
        ctx.fill(tri(CGPoint(x: 30, y: 25), CGPoint(x: 31, y: 11), CGPoint(x: 41, y: 19)), with: .color(pink))
        ctx.fill(tri(CGPoint(x: 70, y: 25), CGPoint(x: 69, y: 11), CGPoint(x: 59, y: 19)), with: .color(pink))

        // head, forehead stripes, muzzle
        ctx.fill(Path(ellipseIn: CGRect(x: 21, y: 13, width: 58, height: 46)), with: .color(fur))
        line(CGPoint(x: 50, y: 15), CGPoint(x: 50, y: 22), stripe, 2.4)
        line(CGPoint(x: 44, y: 16), CGPoint(x: 45, y: 21), stripe, 2.2)
        line(CGPoint(x: 56, y: 16), CGPoint(x: 55, y: 21), stripe, 2.2)
        ctx.fill(Path(ellipseIn: CGRect(x: 38, y: 38, width: 24, height: 16)), with: .color(cream))

        // big eyes with sparkle, blinking now and then
        let closed = t.truncatingRemainder(dividingBy: 3.9) < 0.15
        for x in [39.0, 61.0] {
            if closed {
                var lid = Path()
                lid.move(to: CGPoint(x: x - 4.5, y: 34))
                lid.addQuadCurve(to: CGPoint(x: x + 4.5, y: 34), control: CGPoint(x: x, y: 37.5))
                ctx.stroke(lid, with: .color(ink), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            } else {
                ctx.fill(dot(x, 34, 5.2), with: .color(ink))
                ctx.fill(dot(x + 1.7, 32, 1.9), with: .color(.white))
                ctx.fill(dot(x - 1.6, 36.3, 0.9), with: .color(.white.opacity(0.8)))
            }
        }

        // blush, nose, mouth, whiskers
        ctx.fill(dot(31, 44, 3.6), with: .color(pink.opacity(0.55)))
        ctx.fill(dot(69, 44, 3.6), with: .color(pink.opacity(0.55)))
        ctx.fill(tri(CGPoint(x: 47.5, y: 41.5), CGPoint(x: 52.5, y: 41.5), CGPoint(x: 50, y: 44.5)), with: .color(pink))
        var mouth = Path()
        mouth.move(to: CGPoint(x: 45.5, y: 46.5))
        mouth.addQuadCurve(to: CGPoint(x: 50, y: 46), control: CGPoint(x: 47.5, y: 49.5))
        mouth.addQuadCurve(to: CGPoint(x: 54.5, y: 46.5), control: CGPoint(x: 52.5, y: 49.5))
        ctx.stroke(mouth, with: .color(ink), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        for (dy, k) in [(-2.0, -1.0), (1.0, 0.0), (4.0, 1.0)] {
            line(CGPoint(x: 36, y: 45 + dy), CGPoint(x: 18, y: 43 + dy + 3 * k), ink.opacity(0.45), 0.9)
            line(CGPoint(x: 64, y: 45 + dy), CGPoint(x: 82, y: 43 + dy + 3 * k), ink.opacity(0.45), 0.9)
        }

        // waving paw
        if wave {
            let paw = CGPoint(x: 82, y: 54 + 3 * sin(t * 9))
            line(CGPoint(x: 62, y: 68), paw, fur, 8)
            ctx.fill(dot(paw.x, paw.y, 4.6), with: .color(cream))
        }
    }
}

// MARK: - Flight (full-screen, click-through overlay)

struct FlyView: View {
    let from: CGPoint, to: CGPoint, start: Date, dur: Double

    var body: some View {
        TimelineView(.animation) { tl in
            let p = min(1, max(0, tl.date.timeIntervalSince(start) / dur))
            let e = p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2   // ease in-out
            let pt = point(e), ahead = point(min(1, e + 0.01))
            let tilt = max(-24, min(24, (ahead.y - pt.y) * (ahead.x >= pt.x ? 1.2 : -1.2)))
            ZStack {
                ForEach(1..<9) { k in
                    let q = point(max(0, e - Double(k) * 0.022))
                    Image(systemName: k.isMultiple(of: 2) ? "sparkle" : "heart.fill")
                        .font(.system(size: CGFloat(14 - k)))
                        .foregroundStyle(k.isMultiple(of: 2) ? Color.amber : Cat.pink)
                        .opacity((1 - e) * (0.9 - Double(k) * 0.09))
                        .position(q)
                }
                Cat(size: 96 - 62 * e, wave: true)
                    .rotationEffect(.degrees(tilt))
                    .position(pt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Swoop low through the middle of the screen, loop up, settle onto the notch.
    func point(_ s: Double) -> CGPoint {
        let c1 = CGPoint(x: (from.x + to.x) / 2, y: from.y + 420)
        let c2 = CGPoint(x: to.x + (from.x < to.x ? 420 : -420), y: to.y + 320)
        let u = 1 - s
        let x = u * u * u * from.x + 3 * u * u * s * c1.x + 3 * u * s * s * c2.x + s * s * s * to.x
        let y = u * u * u * from.y + 3 * u * u * s * c1.y + 3 * u * s * s * c2.y + s * s * s * to.y
        return CGPoint(x: x, y: y + sin(s * .pi * 4) * 26 * u)
    }
}

extension Color {
    static let coral = Color(red: 1.0, green: 0.52, blue: 0.40)
}

// MARK: - Reminders tab

struct HealthPane: View {
    let coach: Coach

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Cat(size: 26)
                Text("Reminders").font(sans(13, .semibold))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    if coach.paused {
                        Caps(text: "paused")
                    } else if let r = coach.upcoming {
                        Caps(text: "next: \(r.name) in \(max(0, Int(coach.nextIn(r) / 60)))m")
                    }
                }
                Spacer()
                Button {
                    coach.pausedUntil = coach.paused ? nil : Date().addingTimeInterval(3600)
                } label: {
                    Pill(icon: coach.paused ? "play.fill" : "pause.fill", text: coach.paused ? "resume" : "pause 1h", color: .fg2)
                }
                Button { coach.test() } label: { Pill(icon: "sparkles", text: "test", color: .coral) }
                    .help("show the next reminder now")
            }
            .buttonStyle(Press())

            ScrollView {
                VStack(spacing: 3) { ForEach(coach.routines) { row($0) } }
            }
            .scrollIndicators(.never)
        }
    }

    func row(_ r: Routine) -> some View {
        HStack(spacing: 10) {
            Image(systemName: r.icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(r.on ? Color.coral : Color.fg3)
                .frame(width: 24, height: 24)
                .background((r.on ? Color.coral : Color.white).opacity(0.12), in: Circle())
            Text(r.name).font(sans(12, .semibold)).foregroundStyle(r.on ? Color.fg : Color.fg3)
            Text(r.tip).font(sans(11)).foregroundStyle(Color.fg3).lineLimit(1)
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                Button { coach.setEvery(r, r.every - 5) } label: { Image(systemName: "minus").font(.system(size: 8, weight: .bold)) }
                Text("every \(r.every)m").font(mono(10, .semibold)).frame(width: 66)
                Button { coach.setEvery(r, r.every + 5) } label: { Image(systemName: "plus").font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(Color.fg2)
            .padding(.horizontal, 6).frame(height: 20)
            .background(Color.white.opacity(0.05), in: Capsule())
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Caps(text: !r.on ? "off" : coach.paused ? "paused" : "in \(max(0, Int(coach.nextIn(r) / 60)))m")
                    .frame(width: 52, alignment: .trailing)
            }
            Button { coach.toggle(r) } label: {
                Image(systemName: r.on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14)).foregroundStyle(r.on ? Color.coral : Color.fg3)
            }
            .help(r.on ? "turn off" : "turn on")
        }
        .buttonStyle(Press())
        .padding(.horizontal, 8).padding(.vertical, 6)
        .card(.coral)
    }
}
