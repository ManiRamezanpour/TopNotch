import SwiftUI

// MARK: - Solar Hijri (Jalali) calendar

/// Persian calendar math on top of Foundation's `.persian` calendar: weeks start on Saturday, Friday is the weekend.
enum Jalali {
    static let fa = Locale(identifier: "fa_IR")
    static let cal: Calendar = {
        var c = Calendar(identifier: .persian)
        c.locale = fa
        c.firstWeekday = 7  // شنبه
        return c
    }()
    static let months = cal.monthSymbols
    /// Saturday → Friday, the order the grid draws them in.
    static let weekdays = ["ش", "ی", "د", "س", "چ", "پ", "ج"]
    static let dayNames = ["یکشنبه", "دوشنبه", "سه‌شنبه", "چهارشنبه", "پنجشنبه", "جمعه", "شنبه"]  // by Foundation weekday 1…7

    /// Official holidays that sit on fixed solar dates. The lunar (Hijri) ones move each year and are left out.
    static let holidays: [Int: String] = [
        101: "نوروز", 102: "نوروز", 103: "نوروز", 104: "نوروز",
        112: "روز جمهوری اسلامی", 113: "روز طبیعت",
        314: "رحلت امام خمینی", 315: "قیام ۱۵ خرداد",
        1122: "پیروزی انقلاب اسلامی", 1229: "ملی شدن صنعت نفت",
    ]

    static func ymd(_ d: Date) -> (y: Int, m: Int, d: Int) {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        return (c.year!, c.month!, c.day!)
    }

    static func num(_ n: Int) -> String { n.formatted(.number.grouping(.never).locale(fa)) }

    static func holiday(_ d: Date) -> String? {
        let x = ymd(d)
        return holidays[x.m * 100 + x.d]
    }

    static func off(_ d: Date) -> Bool { cal.component(.weekday, from: d) == 6 || holiday(d) != nil }

    /// First day of the Jalali month `shift` months away from `d`.
    static func month(of d: Date, shift: Int = 0) -> Date {
        let x = ymd(d)
        let first = cal.date(from: DateComponents(year: x.y, month: x.m, day: 1))!
        return cal.date(byAdding: .month, value: shift, to: first)!
    }

    /// The month's days, padded with leading `nil`s so the first one lands in its Saturday-first column.
    static func grid(_ first: Date) -> [Date?] {
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let n = cal.range(of: .day, in: .month, for: first)!.count
        return Array(repeating: nil, count: lead) + (0..<n).map { cal.date(byAdding: .day, value: $0, to: first) }
    }

    /// Day of the year, the year's length, and whole days left until the next Nowruz.
    static func year(_ d: Date) -> (day: Int, of: Int, nowruz: Int) {
        let next = cal.date(from: DateComponents(year: ymd(d).y + 1, month: 1, day: 1))!
        return (cal.ordinality(of: .day, in: .year, for: d)!, cal.range(of: .day, in: .year, for: d)!.count,
                cal.dateComponents([.day], from: cal.startOfDay(for: d), to: next).day!)
    }

    static func long(_ d: Date) -> String {
        let x = ymd(d)
        return "\(dayNames[cal.component(.weekday, from: d) - 1]) \(num(x.d)) \(months[x.m - 1]) \(num(x.y))"
    }

    static func short(_ d: Date) -> String { "\(num(ymd(d).d)) \(months[ymd(d).m - 1])" }
}

// MARK: - Pane

struct CalPane: View {
    @State private var page = Jalali.month(of: Date())
    @State private var picked = Jalali.cal.startOfDay(for: Date())
    @State private var hover: Date?

    let en = Locale(identifier: "en_US")
    var today: Date { Jalali.cal.startOfDay(for: Date()) }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            dayCard.frame(width: 230)
            VStack(spacing: 6) {
                nav
                monthGrid
            }
        }
        .buttonStyle(Press())
    }

    // MARK: day

    var dayCard: some View {
        let x = Jalali.ymd(picked), yr = Jalali.year(picked), isToday = picked == today
        let tint: Color = Jalali.off(picked) ? .hot : .jade
        return VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Caps(text: isToday ? "today" : "picked", color: tint)
                Spacer()
                Text(Jalali.dayNames[Jalali.cal.component(.weekday, from: picked) - 1]).font(sans(13, .medium)).foregroundStyle(Color.fg2)
            }
            Text(Jalali.num(x.d)).font(sans(46, .bold)).foregroundStyle(tint)
                .shadow(color: tint.opacity(0.5), radius: 10)
                .contentTransition(.numericText())
            Text("\(Jalali.months[x.m - 1]) \(Jalali.num(x.y))").font(sans(16, .semibold))
            if let h = Jalali.holiday(picked) {
                Text(h).font(sans(12, .medium)).foregroundStyle(Color.hot).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(picked, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).year().locale(en))
                .font(mono(10, .medium)).foregroundStyle(Color.fg3)
            HStack(spacing: 6) {
                Caps(text: "day \(yr.day)/\(yr.of)")
                Spacer()
                Caps(text: "nowruz in \(yr.nowruz)d", color: .neon)
            }
            Capsule().fill(Color.white.opacity(0.08)).frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(Color.jade).frame(width: g.size.width * Double(yr.day) / Double(yr.of))
                            .shadow(color: Color.jade.opacity(0.6), radius: 3)
                    }
                }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .card(tint)
        .animation(spring, value: picked)
    }

    // MARK: month

    var nav: some View {
        let first = page, last = Jalali.cal.date(byAdding: DateComponents(month: 1, day: -1), to: first)!
        return HStack(spacing: 8) {
            Image(systemName: "calendar").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.jade)
            Text("\(Jalali.months[Jalali.ymd(first).m - 1]) \(Jalali.num(Jalali.ymd(first).y))").font(sans(14, .semibold))
            Caps(text: "\(first.formatted(.dateTime.month(.abbreviated).locale(en))) – \(last.formatted(.dateTime.month(.abbreviated).year().locale(en)))")
            Spacer()
            if page != Jalali.month(of: Date()) || picked != today {
                Button { go(to: Date()) } label: { Pill(icon: "arrow.uturn.backward", text: "today", color: .jade) }
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            // right-to-left: the previous month is to the right
            Button { flip(1) } label: { Image(systemName: "chevron.left") }.help("next month")
            Button { flip(-1) } label: { Image(systemName: "chevron.right") }.help("previous month")
        }
        .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.fg2)
        .frame(height: 22)
    }

    var monthGrid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)
        return LazyVGrid(columns: cols, spacing: 3) {
            ForEach(Array(Jalali.weekdays.enumerated()), id: \.offset) { i, w in
                Text(w).font(sans(10, .bold)).foregroundStyle(i == 6 ? Color.hot.opacity(0.8) : Color.fg3).frame(height: 14)
            }
            ForEach(Array(Jalali.grid(page).enumerated()), id: \.offset) { _, d in
                if let d { cell(d) } else { Color.clear.frame(height: 25) }
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .id(page)
        .transition(.opacity)
    }

    func cell(_ d: Date) -> some View {
        let isToday = d == today, on = d == picked, off = Jalali.off(d)
        let c: Color = isToday ? .black : off ? .hot : .fg
        return VStack(spacing: -1) {
            Text(Jalali.num(Jalali.ymd(d).d)).font(sans(12, isToday || on ? .bold : .medium))
            Text("\(Calendar(identifier: .gregorian).component(.day, from: d))").font(mono(7, .medium)).opacity(0.55)
        }
        .foregroundStyle(c)
        .frame(maxWidth: .infinity).frame(height: 25)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isToday ? Color.jade : Color.white.opacity(on ? 0.12 : hover == d ? 0.07 : 0))
        }
        .overlay {
            if on && !isToday { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.jade.opacity(0.7), lineWidth: 1) }
        }
        .shadow(color: isToday ? Color.jade.opacity(0.6) : .clear, radius: 6)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hover = h ? d : nil } }
        .onTapGesture { withAnimation(spring) { picked = d } }
        .help(Jalali.holiday(d) ?? Jalali.long(d))
    }

    func flip(_ n: Int) { withAnimation(spring) { page = Jalali.month(of: page, shift: n) } }

    func go(to d: Date) {
        withAnimation(spring) {
            page = Jalali.month(of: d)
            picked = Jalali.cal.startOfDay(for: d)
        }
    }
}
