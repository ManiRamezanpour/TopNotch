import SwiftUI

struct UsageOverview: View {
    let agents: Agents

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                tile("5h limit", value: currentValue, detail: currentDetail, color: .ice,
                     progress: agents.accountSession?.percent)
                tile("7d limit", value: weekValue, detail: "all models", color: .neon,
                     progress: agents.accountWeek?.percent)
                tile("credits", value: creditValue, detail: creditDetail, color: .amber,
                     progress: creditProgress)
            }
            if !agents.accountModels.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Caps(text: "Model limits")
                    ForEach(agents.accountModels) { model in
                        HStack(spacing: 7) {
                            Text(model.name).font(sans(10, .medium)).foregroundStyle(Color.fg2).lineLimit(1)
                                .frame(width: 74, alignment: .leading)
                            Meter(frac: min(1, max(0, model.percent / 100)))
                            Text("\(Int(model.percent.rounded()))%")
                                .font(mono(9, .semibold)).foregroundStyle(Color.fg2).monospacedDigit().frame(width: 34, alignment: .trailing)
                        }
                    }
                }
            } else if !agents.modelUsage.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Caps(text: "Model tokens · 7d")
                    ForEach(agents.modelUsage) { item in
                        HStack {
                            Text(item.model).font(sans(9, .medium)).foregroundStyle(Color.fg2)
                            Spacer()
                            Text(fmtTok(item.tokens)).font(mono(9, .semibold)).foregroundStyle(Color.fg2)
                        }
                    }
                }
            }
        }
        .padding(9)
        .card(.claude)
    }

    @ViewBuilder private func tile(_ title: String, value: String, detail: String, color: Color, progress: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Caps(text: title, color: color)
            Text(value).font(sans(13, .semibold)).foregroundStyle(Color.fg).lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(mono(8)).foregroundStyle(Color.fg3).lineLimit(1).minimumScaleFactor(0.7)
            if let progress {
                Meter(frac: min(1, max(0, progress / 100)), n: 14)
            } else {
                Color.clear.frame(height: 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(Color.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    var currentValue: String {
        if let session = agents.accountSession { return "\(Int(session.percent.rounded()))%" }
        return agents.accountUsageLoaded ? "Unavailable" : "\(fmtTok(agents.block)) tok"
    }

    var currentDetail: String {
        if let reset = agents.accountSession?.resetsAt { return "resets \(hhmm(reset.timeIntervalSinceNow))" }
        return agents.accountUsageLoaded ? "Claude plan meter" : "local 5h estimate"
    }

    var weekValue: String {
        if let week = agents.accountWeek { return "\(Int(week.percent.rounded()))%" }
        return agents.accountUsageLoaded ? "Unavailable" : "\(fmtTok(agents.week)) tok"
    }

    var creditValue: String {
        guard let extra = agents.extraUsage else { return agents.accountUsageLoaded ? "Not available" : "Loading…" }
        guard extra.enabled else { return "Off" }
        guard let used = extra.used else { return "Enabled" }
        return money(used)
    }

    var creditDetail: String {
        guard let extra = agents.extraUsage else { return "extra usage" }
        guard extra.enabled else { return "extra usage disabled" }
        guard let limit = extra.limit else { return "credits used" }
        return "of \(money(limit)) monthly"
    }

    var creditProgress: Double? {
        guard let extra = agents.extraUsage, let used = extra.used, let limit = extra.limit, limit > 0 else { return nil }
        return used / limit * 100
    }

    func money(_ minorUnits: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = agents.extraUsage?.currency ?? "USD"
        return formatter.string(from: NSNumber(value: minorUnits / 100)) ?? String(format: "$%.2f", minorUnits / 100)
    }
}

struct ActivityHeatmap: View {
    let days: [[Int]]
    private let cell: CGFloat = 10
    private let gap: CGFloat = 2

    var total: Int { days.flatMap { $0 }.reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caps(text: "Activity · 7 days")
                Spacer()
                Caps(text: "\(total) messages", color: .fg2)
            }
            VStack(alignment: .leading, spacing: gap) {
                HStack(spacing: gap) {
                    Color.clear.frame(width: 28, height: 9)
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hour.isMultiple(of: 6) ? String(format: "%02d", hour) : "")
                            .font(mono(7)).foregroundStyle(Color.fg3)
                            .frame(width: cell, height: 9)
                    }
                }
                ForEach(0..<7, id: \.self) { day in
                    HStack(spacing: gap) {
                        Text(dayDate(day).formatted(.dateTime.weekday(.abbreviated)))
                            .font(mono(8)).foregroundStyle(Color.fg3)
                            .frame(width: 28, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            let count = days.indices.contains(day) && days[day].indices.contains(hour) ? days[day][hour] : 0
                            RoundedRectangle(cornerRadius: 2)
                                .fill(shade(count))
                                .frame(width: cell, height: cell)
                                .help("\(dayDate(day).formatted(date: .complete, time: .omitted)) · \(String(format: "%02d", hour)):00 · \(count) messages")
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Caps(text: "less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2).fill(shade(level == 0 ? 0 : (level - 1) * 2 + 1))
                        .frame(width: 10, height: 10)
                }
                Caps(text: "more")
                Spacer()
                Caps(text: "hour of day", color: .fg3)
            }
        }
        .padding(9)
        .card(.claude)
    }

    private func dayDate(_ row: Int) -> Date {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .day, value: row - 6, to: today) ?? today
    }

    private func shade(_ count: Int) -> Color {
        let opacity: Double = switch count {
        case 0: 0.07
        case 1: 0.30
        case 2..<4: 0.48
        case 4..<7: 0.70
        default: 0.95
        }
        return count == 0 ? Color.white.opacity(opacity) : Color.claude.opacity(opacity)
    }
}
