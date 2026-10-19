import AppKit
import SwiftUI

// MARK: - Model

struct Routine: Codable, Identifiable, Equatable {
    let id: String
    var name: String, icon: String, tip: String
    var every: Int     // minutes between reminders
    var secs: Int      // 0 = just tap done; >0 = guided countdown
    var on = true
}

struct HealthLog: Codable {
    let id: String, at: Date, done: Bool
}

private func load<T: Decodable>(_ key: String) -> T? {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
}
private func save<T: Encodable>(_ key: String, _ v: T) {
    UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: key)
}

/// The monkey's brain: when each break is due, what you did about it, and your streak.
@Observable final class Coach {
    var routines: [Routine] { didSet { save("routines", routines) } }
    var log: [HealthLog] { didSet { save("healthLog", log) } }
    var due: Routine?          // the break on screen right now
    var countdown: Int?        // seconds left in a guided break
    var pausedUntil: Date?

    @ObservationIgnored var last: [String: Date]   // when each routine last fired/was handled
    @ObservationIgnored var onDue: ((Routine) -> Void)?
    @ObservationIgnored var onClear: (() -> Void)?
    @ObservationIgnored var canInterrupt: () -> Bool = { true }
    @ObservationIgnored private var timer: Timer?

    static let defaults = [
        Routine(id: "blink", name: "Blink break", icon: "eye", tip: "Look at something far away and blink slowly.", every: 20, secs: 20),
        Routine(id: "neck", name: "Neck & posture", icon: "figure.mind.and.body", tip: "Sit tall, slow neck tilts left and right, chin tucks.", every: 40, secs: 20),
        Routine(id: "squeeze", name: "Hand squeeze", icon: "hand.raised.fingers.spread", tip: "Squeeze both fists 10×, then spread your fingers wide.", every: 45, secs: 0),
        Routine(id: "stand", name: "Stand & stretch", icon: "figure.stand", tip: "Stand up, reach for the ceiling, roll your shoulders.", every: 60, secs: 30),
        Routine(id: "water", name: "Water", icon: "drop.fill", tip: "Drink a glass of water.", every: 60, secs: 0),
        Routine(id: "breathe", name: "Breathe", icon: "wind", tip: "Box breathing: in 4, hold 4, out 4, hold 4.", every: 90, secs: 60),
    ]

    init() {
        routines = load("routines") ?? Self.defaults
        log = (load("healthLog") ?? [] as [HealthLog]).filter { $0.at > Date().addingTimeInterval(-30 * 86400) }
        last = Dictionary(uniqueKeysWithValues: (load("routines") ?? Self.defaults).map { ($0.id, Date()) })
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    /// Most overdue enabled routine at `now`, if any is due.
    static func next(_ rs: [Routine], last: [String: Date], now: Date) -> Routine? {
        rs.filter(\.on)
            .map { r in (r, now.timeIntervalSince(last[r.id] ?? now) - Double(r.every * 60)) }
            .filter { $0.1 >= 0 }
            .max { $0.1 < $1.1 }?.0
    }

    /// Consecutive days (ending today, or yesterday if today isn't there yet) with ≥ `min` breaks done.
    static func streak(_ log: [HealthLog], now: Date, min: Int = 3) -> Int {
        let cal = Calendar.current
        let counts = Dictionary(grouping: log.filter(\.done)) { cal.startOfDay(for: $0.at) }.mapValues(\.count)
        var day = cal.startOfDay(for: now), n = 0
        if counts[day, default: 0] < min { day = cal.date(byAdding: .day, value: -1, to: day)! }
        while counts[day, default: 0] >= min {
            n += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }

    var streak: Int { Self.streak(log, now: Date()) }
    var doneToday: Int { log.filter { $0.done && Calendar.current.isDateInToday($0.at) }.count }
    func today(_ id: String) -> Int { log.filter { $0.id == id && $0.done && Calendar.current.isDateInToday($0.at) }.count }
    func nextIn(_ r: Routine) -> Double { Double(r.every * 60) - Date().timeIntervalSince(last[r.id] ?? Date()) }
    var paused: Bool { (pausedUntil ?? .distantPast) > Date() }

    private func tick() {
        // 5 min without touching the Mac = you already took a break
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle > 300 { for r in routines { last[r.id] = Date() }; return }
        guard due == nil, !paused, canInterrupt(), let r = Self.next(routines, last: last, now: Date()) else { return }
        trigger(r)
    }

    func trigger(_ r: Routine) {
        due = r
        countdown = nil
        onDue?(r)
        // ignored for 2 minutes → quietly snooze, no nagging
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            if self?.due?.id == r.id, self?.countdown == nil { self?.snooze() }
        }
    }

    func breakNow() {
        guard due == nil, let r = Self.next(routines, last: last, now: .distantFuture) else { return }
        trigger(r)
    }

    func start() {
        guard let r = due, r.secs > 0 else { return }
        countdown = r.secs
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self, let c = countdown else { t.invalidate(); return }
            countdown = c - 1
            if c <= 1 { t.invalidate() }   // view sees 0 → cheers → finish(true)
        }
    }

    func finish(_ done: Bool) {
        guard let r = due else { return }
        log.append(HealthLog(id: r.id, at: Date(), done: done))
        last[r.id] = Date()
        clear()
    }

    func snooze() {
        guard let r = due else { return }
        last[r.id] = Date().addingTimeInterval(300 - Double(r.every * 60))  // due again in 5 min
        clear()
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        countdown = nil
        due = nil
        onClear?()
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

// MARK: - The monkey

/// Hand-drawn vector monkey: red sweatband, banana in hand, swaying tail, blinking eyes.
struct Monkey: View {
    var size: CGFloat = 64
    var blinkFast = false   // eye exercise: blink along with you
    var cheer = false       // arms up, banana waving

    static let fur = Color(red: 0.50, green: 0.31, blue: 0.15)
    static let furDark = Color(red: 0.29, green: 0.16, blue: 0.07)
    static let skin = Color(red: 0.97, green: 0.82, blue: 0.65)
    static let band = Color(red: 1.0, green: 0.24, blue: 0.36)
    static let banana = Color(red: 1.0, green: 0.85, blue: 0.22)

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, sz in
                ctx.scaleBy(x: sz.width / 100, y: sz.height / 100)
                Self.draw(&ctx, t: tl.date.timeIntervalSinceReferenceDate, blinkFast: blinkFast, cheer: cheer)
            }
        }
        .frame(width: size, height: size)
    }

    static func draw(_ ctx: inout GraphicsContext, t: Double, blinkFast: Bool, cheer: Bool) {
        func dot(_ x: Double, _ y: Double, _ r: Double) -> Path { Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)) }
        func limb(_ a: CGPoint, _ b: CGPoint, _ c: Color, _ w: Double) {
            var p = Path()
            p.move(to: a)
            p.addLine(to: b)
            ctx.stroke(p, with: .color(c), style: StrokeStyle(lineWidth: w, lineCap: .round))
        }
        let sway = sin(t * 2.2)

        // tail
        var tail = Path()
        tail.move(to: CGPoint(x: 62, y: 80))
        tail.addCurve(to: CGPoint(x: 88, y: 50 + 4 * sway), control1: CGPoint(x: 92, y: 90), control2: CGPoint(x: 98, y: 60 + 6 * sway))
        tail.addQuadCurve(to: CGPoint(x: 81, y: 44 + 4 * sway), control: CGPoint(x: 82, y: 50 + 4 * sway))
        ctx.stroke(tail, with: .color(fur), style: StrokeStyle(lineWidth: 5, lineCap: .round))

        // body, belly, feet
        ctx.fill(Path(ellipseIn: CGRect(x: 32, y: 54, width: 36, height: 34)), with: .color(fur))
        ctx.fill(Path(ellipseIn: CGRect(x: 40, y: 62, width: 20, height: 22)), with: .color(skin))
        ctx.fill(Path(ellipseIn: CGRect(x: 32, y: 82, width: 15, height: 9)), with: .color(furDark))
        ctx.fill(Path(ellipseIn: CGRect(x: 53, y: 82, width: 15, height: 9)), with: .color(furDark))

        // free arm
        let fist = cheer ? CGPoint(x: 21, y: 42 + 4 * sin(t * 9)) : CGPoint(x: 25, y: 77)
        limb(CGPoint(x: 38, y: 62), fist, fur, 8)
        ctx.fill(dot(fist.x, fist.y, 4.3), with: .color(skin))

        // ears + head + face
        for x in [27.0, 73.0] {
            ctx.fill(dot(x, 36, 8.5), with: .color(fur))
            ctx.fill(dot(x, 36, 5), with: .color(skin))
        }
        ctx.fill(dot(50, 36, 22), with: .color(fur))
        ctx.fill(dot(42.5, 33, 9), with: .color(skin))
        ctx.fill(dot(57.5, 33, 9), with: .color(skin))
        ctx.fill(Path(ellipseIn: CGRect(x: 35, y: 34, width: 30, height: 20)), with: .color(skin))

        // sweatband, clipped to the head, with fluttering ties
        ctx.drawLayer { l in
            l.clip(to: dot(50, 36, 22))
            l.fill(Path(CGRect(x: 26, y: 16, width: 48, height: 7.5)), with: .color(band))
            l.fill(Path(CGRect(x: 26, y: 19.2, width: 48, height: 1.3)), with: .color(.white.opacity(0.85)))
        }
        let f = 3 * sin(t * 7)
        limb(CGPoint(x: 69, y: 19), CGPoint(x: 82, y: 13 + f), band, 3.5)
        limb(CGPoint(x: 69, y: 21), CGPoint(x: 80, y: 25 + f * 0.7), band, 3.5)

        // eyes (blink), cheeks, nose, smile
        let period = blinkFast ? 1.2 : 3.7
        let closed = t.truncatingRemainder(dividingBy: period) < 0.15
        for x in [44.0, 56.0] {
            if closed {
                limb(CGPoint(x: x - 3, y: 33), CGPoint(x: x + 3, y: 33), furDark, 1.7)
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: 29.5, width: 5.2, height: 7)), with: .color(furDark))
                ctx.fill(dot(x + 0.9, 31.3, 1.1), with: .color(.white))
            }
        }
        ctx.fill(dot(38, 43.5, 3), with: .color(Color(red: 1, green: 0.5, blue: 0.55).opacity(0.5)))
        ctx.fill(dot(62, 43.5, 3), with: .color(Color(red: 1, green: 0.5, blue: 0.55).opacity(0.5)))
        ctx.fill(dot(48, 40.5, 1), with: .color(furDark))
        ctx.fill(dot(52, 40.5, 1), with: .color(furDark))
        var smile = Path()
        smile.move(to: CGPoint(x: 44, y: 45))
        smile.addQuadCurve(to: CGPoint(x: 56, y: 45), control: CGPoint(x: 50, y: cheer ? 54 : 50))
        ctx.stroke(smile, with: .color(furDark), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))

        // banana arm, in front of everything
        let wave = cheer ? 7 * sin(t * 9) : 3 * sin(t * 3)
        let hand = CGPoint(x: 79, y: (cheer ? 40 : 58) + wave)
        limb(CGPoint(x: 62, y: 62), hand, fur, 8)
        // banana: a filled crescent held at the stem, curving up and out
        let stem = CGPoint(x: hand.x + 1, y: hand.y + 3), tip = CGPoint(x: hand.x + 4, y: hand.y - 25)
        var fruit = Path()
        fruit.move(to: stem)
        fruit.addQuadCurve(to: tip, control: CGPoint(x: hand.x + 19, y: hand.y - 9))
        fruit.addQuadCurve(to: stem, control: CGPoint(x: hand.x + 8, y: hand.y - 11))
        fruit.closeSubpath()
        ctx.fill(fruit, with: .color(banana))
        ctx.stroke(fruit, with: .color(Color(red: 0.86, green: 0.64, blue: 0.08)), lineWidth: 0.9)
        ctx.fill(dot(tip.x, tip.y, 1.7), with: .color(furDark))
        ctx.fill(dot(hand.x, hand.y, 4.3), with: .color(skin))
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
            let tilt = max(-28, min(28, atan2(ahead.y - pt.y, ahead.x - pt.x) * 180 / .pi * (ahead.x >= pt.x ? 0.35 : -0.35)))
            ZStack {
                ForEach(1..<9) { k in
                    let q = point(max(0, e - Double(k) * 0.022))
                    Image(systemName: k.isMultiple(of: 2) ? "sparkle" : "circle.fill")
                        .font(.system(size: CGFloat(14 - k)))
                        .foregroundStyle(k.isMultiple(of: 3) ? Color.neon : Monkey.banana)
                        .opacity((1 - e) * (0.9 - Double(k) * 0.09))
                        .position(q)
                }
                Monkey(size: 104 - 42 * e, cheer: true)
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
        return CGPoint(x: x, y: y + sin(s * .pi * 4) * 26 * u)   // bobbing, calming down on landing
    }
}

// MARK: - The break card on the notch

extension Color {
    static let coral = Color(red: 1.0, green: 0.52, blue: 0.40)
}

struct CoachView: View {
    let coach: Coach, s: NotchState
    @State private var cheer = false

    var body: some View {
        ZStack(alignment: .top) {
            if let r = coach.due {
                let shape = NotchShape(top: 9, bottom: 24)
                ZStack {
                    Color.black
                    RadialGradient(colors: [Color.coral.opacity(0.32), .clear], center: UnitPoint(x: 0.2, y: 1.1), startRadius: 0, endRadius: 300)
                }
                .clipShape(shape)
                .overlay(shape.stroke(LinearGradient(colors: [.clear, Color.coral.opacity(0.6)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .shadow(color: .coral.opacity(0.35), radius: 20, y: 6)

                VStack(spacing: 0) {
                    HStack {
                        HStack(spacing: 4) {
                            Image(systemName: "heart.fill").font(.system(size: 9, weight: .bold))
                            Caps(text: "health break", color: .coral)
                        }
                        .foregroundStyle(Color.coral)
                        Spacer(minLength: s.notch.width + 12)
                        HStack(spacing: 3) {
                            Image(systemName: "flame.fill").font(.system(size: 9, weight: .bold))
                            Text("\(coach.streak)d").font(mono(10, .bold))
                        }
                        .foregroundStyle(Color.amber)
                    }
                    .frame(height: s.notch.height)

                    HStack(spacing: 12) {
                        ZStack {
                            if let c = coach.countdown, r.secs > 0 {
                                Circle().stroke(Color.white.opacity(0.1), lineWidth: 3)
                                Circle().trim(from: 0, to: Double(c) / Double(r.secs))
                                    .stroke(Color.coral, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                    .rotationEffect(.degrees(-90))
                                    .animation(.linear(duration: 1), value: c)
                            }
                            Monkey(size: 66, blinkFast: r.id == "blink" && coach.countdown != nil, cheer: cheer)
                                .offset(y: cheer ? -6 : 0)
                        }
                        .frame(width: 70, height: 70)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: r.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.coral)
                                Text(cheer ? "Nice! +1 🍌" : r.name).font(sans(14, .bold)).foregroundStyle(.white)
                                if let c = coach.countdown, c > 0 { Text("\(c)s").font(mono(12, .bold)).foregroundStyle(Color.coral) }
                            }
                            Text(r.tip).font(sans(12)).foregroundStyle(Color.fg2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 6) {
                                if coach.countdown != nil {   // guided break running: allow finishing early
                                    btn("checkmark", "done", .neon, filled: false) { celebrate() }
                                } else {
                                    if r.secs > 0 { btn("play.fill", "start \(r.secs)s", .coral, filled: true) { coach.start() } }
                                    btn("checkmark", "done", .neon, filled: r.secs == 0) { celebrate() }
                                    btn("moon.zzz", "5m", .fg2, filled: false) { coach.snooze() }
                                    btn("forward.end.fill", "skip", .fg3, filled: false) { coach.finish(false) }
                                }
                            }
                            .padding(.top, 2)
                            .opacity(cheer ? 0 : 1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 20)
                .transition(.opacity)
            }
        }
        .frame(width: AppDelegate.coachSize.width, height: s.notch.height + AppDelegate.coachSize.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(spring, value: coach.due?.id)
        .onChange(of: coach.countdown) { _, c in if c == 0 { celebrate() } }
    }

    func btn(_ icon: String, _ text: String, _ c: Color, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold))
                Text(text.uppercased()).font(mono(10, .bold)).kerning(0.8)
            }
            .foregroundStyle(filled ? Color.black : c)
            .padding(.horizontal, 10).frame(height: 24)
            .background(filled ? c : c.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(c.opacity(filled ? 0 : 0.35), lineWidth: 0.5))
        }
        .buttonStyle(Press())
    }

    func celebrate() {
        guard !cheer else { return }
        NSSound(named: "Purr")?.play()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.4)) { cheer = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            coach.finish(true)
            cheer = false
        }
    }
}

// MARK: - Health tab

struct HealthPane: View {
    let coach: Coach

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Monkey(size: 26)
                Text("Coach").font(sans(13, .semibold))
                Caps(text: "\(coach.doneToday) done today")
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill").font(.system(size: 9, weight: .bold))
                    Caps(text: "\(coach.streak) day streak", color: .amber)
                }
                .foregroundStyle(Color.amber)
                Spacer()
                Button {
                    coach.pausedUntil = coach.paused ? nil : Date().addingTimeInterval(3600)
                } label: {
                    Pill(icon: coach.paused ? "play.fill" : "pause.fill", text: coach.paused ? "resume" : "pause 1h", color: .fg2)
                }
                Button { coach.breakNow() } label: { Pill(icon: "heart.fill", text: "break now", color: .coral) }
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
            VStack(alignment: .leading, spacing: 1) {
                Text(r.name).font(sans(12, .semibold)).foregroundStyle(r.on ? Color.fg : Color.fg3)
                Text(r.tip).font(sans(10)).foregroundStyle(Color.fg3).lineLimit(1)
            }
            Spacer(minLength: 6)
            HStack(spacing: 2) {
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                Text("\(coach.today(r.id))").font(mono(11, .bold))
            }
            .foregroundStyle(coach.today(r.id) > 0 ? Color.neon : Color.fg3)
            .frame(width: 30)
            HStack(spacing: 4) {
                Button { coach.setEvery(r, r.every - 5) } label: { Image(systemName: "minus").font(.system(size: 8, weight: .bold)) }
                Text("\(r.every)m").font(mono(10, .semibold)).frame(width: 34)
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
        .padding(.horizontal, 8).padding(.vertical, 5)
        .card(.coral)
    }
}
