import AppKit
import SwiftUI

// MARK: - Reminders

struct Routine: Codable, Identifiable, Equatable {
    let id: String
    var name: String, icon: String, tip: String
    var every: Int   // minutes between reminders
    var on = true
}

/// Gentle health reminders: says it, then gets out of the way. No tracking.
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

extension Color {
    static let coral = Color(red: 1.0, green: 0.52, blue: 0.40)
}

// MARK: - The edge tab: a liquid blob living on the right edge, above the Dock

@Observable final class Side {
    enum Mode: Equatable { case idle, menu, remind(Routine) }
    var mode = Mode.idle
    var magnet = 0.0    // 0…1, how close the pointer is
    var pullY = 0.0     // pointer height in the canvas, where the liquid bulges
    var ends = Date()   // reminder countdown end

    static let canvas = CGSize(width: 340, height: 340)
    static let base: CGFloat = 36       // gap under the blob, inside the window
    static let hold = 20.0              // seconds a reminder waits for you

    /// (protrusion from the edge, height, corner radius, edge flare) for each mode
    var geo: (w: CGFloat, h: CGFloat, r: CGFloat, f: CGFloat) {
        switch mode {
        case .idle: (13 + 10 * magnet, 46 + 18 * magnet, 7, 7)
        case .menu: (304, 236, 22, 12)
        case .remind: (300, 92, 22, 12)
        }
    }
}

/// A tab of liquid stuck to the right screen edge: concave flares where it meets the edge, rounded outer
/// corners, and a leading side that ripples at rest and bulges toward a nearby pointer.
struct EdgeBlob: Shape {
    var w: CGFloat, h: CGFloat, r: CGFloat, f: CGFloat, bulge: CGFloat
    var bulgeY: CGFloat, wobble: CGFloat, t: Double

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { .init(.init(w, h), .init(r, .init(f, bulge))) }
        set { (w, h, r, f, bulge) = (newValue.first.first, newValue.first.second, newValue.second.first,
                                     newValue.second.second.first, newValue.second.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        let edge = rect.maxX + 1, bottom = rect.maxY - Side.base, top = bottom - h, left = edge - 1 - w
        let r = min(r, w * 0.9, h / 2), f = min(f, max(0, w - r))   // keep the outline from folding back
        var p = Path()
        p.move(to: CGPoint(x: edge, y: top - f))
        p.addQuadCurve(to: CGPoint(x: edge - f, y: top), control: CGPoint(x: edge, y: top))
        p.addLine(to: CGPoint(x: left + r, y: top))
        p.addQuadCurve(to: CGPoint(x: left, y: top + r), control: CGPoint(x: left, y: top))
        let span = max(1, h - 2 * r)
        for y in stride(from: top + r, through: bottom - r, by: 1.5) {
            let k = sin(.pi * (y - top - r) / span)   // 0 at the corners, so they stay attached
            let ripple = wobble * sin(y * 0.16 + t * 2.4) * k
            let pull = bulge * exp(-pow(y - bulgeY, 2) / (2 * 20 * 20)) * k
            p.addLine(to: CGPoint(x: left - ripple - pull, y: y))
        }
        p.addLine(to: CGPoint(x: left, y: bottom - r))
        p.addQuadCurve(to: CGPoint(x: left + r, y: bottom), control: CGPoint(x: left, y: bottom))
        p.addLine(to: CGPoint(x: edge - f, y: bottom))
        p.addQuadCurve(to: CGPoint(x: edge, y: bottom + f), control: CGPoint(x: edge, y: bottom))
        p.closeSubpath()
        return p
    }
}

struct SideView: View {
    let side: Side, coach: Coach

    var body: some View {
        let g = side.geo, idle = side.mode == .idle
        let c = Side.canvas, bottom = c.height - Side.base
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: !idle)) { tl in
                let blob = EdgeBlob(w: g.w, h: g.h, r: g.r, f: g.f, bulge: idle ? 14 * side.magnet : 0, bulgeY: side.pullY,
                                    wobble: idle ? 1.4 : 0, t: tl.date.timeIntervalSinceReferenceDate)
                blob.fill(LinearGradient(colors: [Color(white: 0.09), .black], startPoint: .leading, endPoint: .trailing))
                    .overlay(blob.stroke(Color.white.opacity(idle ? 0.18 : 0.10), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.45), radius: 10, x: -2)
                    .shadow(color: .coral.opacity(idle ? 0.25 * side.magnet : 0.18), radius: 14)
            }

            Group {
                switch side.mode {
                case .idle: EmptyView()
                case .menu: menu
                case let .remind(r): reminder(r)
                }
            }
            .frame(width: g.w - 30, height: g.h, alignment: .topLeading)
            .position(x: c.width - g.w / 2 - 6, y: bottom - g.h / 2)
            .transition(.opacity.animation(.easeOut(duration: 0.15).delay(0.12)))
        }
        .frame(width: c.width, height: c.height)
        .foregroundStyle(Color.fg)
        .animation(.spring(response: 0.45, dampingFraction: 0.76), value: side.mode)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: side.magnet)
    }

    func reminder(_ r: Routine) -> some View {
        TimelineView(.animation) { tl in
            let left = max(0, side.ends.timeIntervalSince(tl.date))
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
                    Circle().trim(from: 0, to: left / Side.hold)
                        .stroke(Color.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: r.icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.coral)
                }
                .frame(width: 48, height: 48)
                .shadow(color: .coral.opacity(0.5), radius: 8)
                VStack(alignment: .leading, spacing: 3) {
                    Caps(text: "health break · \(Int(left.rounded(.up)))s", color: .coral)
                    Text(r.name).font(sans(16, .bold)).foregroundStyle(.white)
                    Text(r.tip).font(sans(12)).foregroundStyle(Color.fg2).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .padding(.leading, 18)
        }
    }

    var menu: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "heart.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.coral)
                Text("Reminders").font(sans(13, .semibold))
                Spacer()
                Button {
                    coach.pausedUntil = coach.paused ? nil : Date().addingTimeInterval(3600)
                } label: { Pill(icon: coach.paused ? "play.fill" : "pause.fill", text: coach.paused ? "resume" : "1h", color: .fg2) }
                    .help(coach.paused ? "resume reminders" : "pause reminders for an hour")
                Button { coach.test() } label: { Pill(icon: "sparkles", text: "test", color: .coral) }
                    .help("show the next reminder now")
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if coach.paused { Caps(text: "paused for now") }
                else if let r = coach.upcoming { Caps(text: "next: \(r.name) in \(max(0, Int(coach.nextIn(r) / 60)))m") }
            }
            VStack(spacing: 2) { ForEach(coach.routines) { row($0) } }
        }
        .buttonStyle(Press())
        .padding(.leading, 16).padding(.top, 14)
    }

    func row(_ r: Routine) -> some View {
        HStack(spacing: 8) {
            Image(systemName: r.icon).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(r.on ? Color.coral : Color.fg3).frame(width: 18)
            Text(r.name).font(sans(12, .medium)).foregroundStyle(r.on ? Color.fg : Color.fg3).lineLimit(1)
            Spacer(minLength: 4)
            Button { coach.setEvery(r, r.every - 5) } label: { Image(systemName: "minus").font(.system(size: 8, weight: .bold)) }
            Text("\(r.every)m").font(mono(10, .semibold)).foregroundStyle(Color.fg2).frame(width: 34)
            Button { coach.setEvery(r, r.every + 5) } label: { Image(systemName: "plus").font(.system(size: 8, weight: .bold)) }
            Button { coach.toggle(r) } label: {
                Image(systemName: r.on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13)).foregroundStyle(r.on ? Color.coral : Color.fg3)
            }
            .padding(.leading, 4)
        }
        .foregroundStyle(Color.fg2)
        .frame(height: 25)
    }
}
