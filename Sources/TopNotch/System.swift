import AppKit
import IOKit
import IOKit.ps
import SwiftUI

// MARK: - System status: CPU, memory, network, battery, disk, thermals

struct Battery: Equatable {
    var pct: Int, plugged: Bool, charging: Bool
    var mins: Int?  // to empty on battery, to full while charging; nil while macOS is still estimating
    var cycles: Int?, health: Int?, temp: Double?, watts: Int?
}

struct Proc: Equatable, Identifiable {
    let id: Int32, name: String, cpu: Double, mem: UInt64
}

@Observable final class Stats {
    static let span = 60  // samples per sparkline, 2s apart → the last two minutes

    var cpu = 0.0
    var mem = 0.0
    var memUsed: UInt64 = 0
    let memTotal = ProcessInfo.processInfo.physicalMemory
    let cores = ProcessInfo.processInfo.activeProcessorCount
    var down = 0.0  // bytes/s over Wi-Fi / Ethernet / cellular, VPN tunnels not double-counted
    var up = 0.0
    var cpuHist: [Double] = []
    var memHist: [Double] = []
    var downHist: [Double] = []
    var upHist: [Double] = []
    var battery: Battery?
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 1
    var thermal = ProcessInfo.processInfo.thermalState
    var top: [Proc] = []
    /// Power and thermal news for the notch: plugged in, unplugged, battery low, running hot.
    @ObservationIgnored var onEvent: ((Flash) -> Void)?

    @ObservationIgnored private var watching = false  // the pane is on screen: only then do we pay for `ps`
    @ObservationIgnored private let q = DispatchQueue(label: "topnotch.stats")
    @ObservationIgnored private var lastTicks: (busy: UInt64, total: UInt64)?  // q only
    @ObservationIgnored private var lastNet: [String: (i: UInt32, o: UInt32)] = [:]  // q only
    @ObservationIgnored private var lastAt = Date()  // q only
    @ObservationIgnored private var n = 0
    private static let host = mach_host_self()

    init() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    func watch(_ on: Bool) {
        watching = on
        if on { q.async { [weak self] in let t = Self.topProcs(); DispatchQueue.main.async { self?.top = t } } }
    }

    func poll() {
        let watch = watching, slow = n % 15 == 0  // disk every 30s
        n += 1
        q.async { [weak self] in
            guard let self else { return }
            let now = Date(), dt = max(0.5, now.timeIntervalSince(lastAt))
            lastAt = now
            var cpu: Double?
            if let t = Self.ticks() {
                if let l = lastTicks, t.total > l.total { cpu = Double(t.busy - l.busy) / Double(t.total - l.total) }
                lastTicks = t
            }
            let used = Self.memUsed()
            let net = Self.netBytes()
            var dIn: UInt64 = 0, dOut: UInt64 = 0
            for (k, v) in net {
                guard let l = lastNet[k] else { continue }
                dIn += UInt64(v.i &- l.i); dOut += UInt64(v.o &- l.o)  // 32-bit counters wrap at 4 GB
            }
            let primed = !lastNet.isEmpty
            lastNet = net
            let bat = Self.battery()
            let disk = slow ? Self.disk() : nil
            let top = watch ? Self.topProcs() : nil
            let thermal = ProcessInfo.processInfo.thermalState

            DispatchQueue.main.async {
                if let cpu { self.cpu = cpu; Self.push(&self.cpuHist, cpu) }
                if let used {
                    self.memUsed = used
                    self.mem = Double(used) / Double(max(1, self.memTotal))
                    Self.push(&self.memHist, self.mem)
                }
                if primed {
                    self.down = Double(dIn) / dt; self.up = Double(dOut) / dt
                    Self.push(&self.downHist, self.down); Self.push(&self.upHist, self.up)
                }
                if let disk { (self.diskFree, self.diskTotal) = disk }
                if let top { self.top = top }
                self.events(old: self.battery, new: bat, oldHeat: self.thermal, heat: thermal)
                if self.battery != bat { self.battery = bat }
                self.thermal = thermal
            }
        }
    }

    private static func push(_ h: inout [Double], _ v: Double) {
        h.append(v)
        if h.count > span { h.removeFirst(h.count - span) }
    }

    private func events(old: Battery?, new: Battery?, oldHeat: ProcessInfo.ThermalState, heat: ProcessInfo.ThermalState) {
        if heat.rawValue >= ProcessInfo.ThermalState.serious.rawValue, heat.rawValue > oldHeat.rawValue {
            onEvent?(Flash(icon: "flame.fill", color: .hot, app: "System", title: "Running hot",
                           body: "thermal \(heat.label) · \(Int(cpu * 100))% cpu", tab: .sys, secs: 6))
        }
        guard let o = old, let b = new else { return }
        if b.plugged != o.plugged {
            let left = b.mins.map { " · \(mins($0)) left" } ?? ""
            onEvent?(b.plugged
                ? Flash(icon: "bolt.fill", color: .neon, app: "Power", title: "Charging", body: "\(b.pct)%", tab: .sys, secs: 4)
                : Flash(icon: b.icon, color: .amber, app: "Power", title: "On battery", body: "\(b.pct)%" + left, tab: .sys, secs: 4))
        } else if !b.plugged, [20, 10, 5].contains(where: { o.pct > $0 && b.pct <= $0 }) {
            NSSound(named: "Funk")?.play()
            onEvent?(Flash(icon: "battery.25percent", color: .hot, app: "Power", title: "Battery low",
                           body: "\(b.pct)% left", tab: .sys, secs: 7))
        }
    }

    // MARK: probes (all safe off the main thread)

    static func ticks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &n) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks  // user, system, idle, nice
        let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)
        return (busy, busy + UInt64(t.2))
    }

    /// "Memory Used" the way Activity Monitor counts it: app memory + wired + compressed.
    static func memUsed() -> UInt64? {
        var s = vm_statistics64()
        var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(host, HOST_VM_INFO64, $0, &n) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let app = max(0, Int64(s.internal_page_count) - Int64(s.purgeable_count))
        return UInt64(app + Int64(s.wire_count) + Int64(s.compressor_page_count)) * UInt64(vm_kernel_page_size)
    }

    /// Byte counters per physical interface (en* = Wi-Fi/Ethernet, pdp_ip* = cellular).
    static func netBytes() -> [String: (i: UInt32, o: UInt32)] {
        var out: [String: (i: UInt32, o: UInt32)] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }
        var p = head
        while let a = p?.pointee {
            p = a.ifa_next
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK), let data = a.ifa_data else { continue }
            let name = String(cString: a.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            out[name] = (d.ifi_ibytes, d.ifi_obytes)
        }
        return out
    }

    static func battery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let plugged = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let m = (charging ? d[kIOPSTimeToFullChargeKey] : plugged ? nil : d[kIOPSTimeToEmptyKey]) as? Int
            var b = Battery(pct: cur * 100 / max, plugged: plugged, charging: charging, mins: m.flatMap { $0 > 0 ? $0 : nil })
            smart(&b)
            return b
        }
        return nil
    }

    /// Cycle count, wear, temperature and charger watts from the battery's own controller.
    static func smart(_ b: inout Battery) {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard s != 0 else { return }
        defer { IOObjectRelease(s) }
        func prop(_ k: String) -> Any? { IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() }
        b.cycles = prop("CycleCount") as? Int
        // newer macOS nests capacities in BatteryData; Nominal/Design is what Settings calls "Maximum Capacity"
        let data = prop("BatteryData") as? [String: Any] ?? [:]
        let full = data["NominalChargeCapacity"] as? Int ?? prop("NominalChargeCapacity") as? Int ?? prop("AppleRawMaxCapacity") as? Int
        if let full, let design = data["DesignCapacity"] as? Int ?? prop("DesignCapacity") as? Int, design > 0 {
            b.health = min(100, full * 100 / design)
        }
        if let t = prop("Temperature") as? Int { b.temp = Double(t) / 100 }  // centi-°C
        if b.plugged, let a = prop("AdapterDetails") as? [String: Any], let w = a["Watts"] as? Int, w > 0 { b.watts = w }
    }

    static func disk() -> (Int64, Int64)? {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        guard let f = v?.volumeAvailableCapacityForImportantUsage, let t = v?.volumeTotalCapacity else { return nil }
        return (f, Int64(t))
    }

    static func topProcs() -> [Proc] {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]  // sorted by CPU
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").lazy
            .compactMap(parseProc).filter { $0.name != "ps" }.prefix(5).map { $0 }
    }

    /// "  412  23.5  81232 WindowServer" → pid, %cpu, rss (KB → bytes), name (may contain spaces)
    static func parseProc(_ line: Substring) -> Proc? {
        let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard f.count == 4, let pid = Int32(f[0]), let c = Double(f[1]), let kb = UInt64(f[2]) else { return nil }
        return Proc(id: pid, name: String(f[3]).trimmingCharacters(in: .whitespaces), cpu: c, mem: kb * 1024)
    }
}

/// 1536 → "1.5K": 1024 steps, short enough for a HUD.
func fmtBytes(_ b: Double) -> String {
    let u = ["B", "K", "M", "G", "T"]
    var v = max(0, b), i = 0
    while v >= 1000, i < u.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v))B" : String(format: v < 10 ? "%.1f" : "%.0f", v) + u[i]
}

func mins(_ m: Int) -> String { m >= 60 ? "\(m / 60)h\(String(format: "%02d", m % 60))m" : "\(m)m" }

extension ProcessInfo.ThermalState {
    var label: String {
        switch self { case .nominal: "cool"; case .fair: "warm"; case .serious: "hot"; case .critical: "critical"; @unknown default: "?" }
    }
    var color: Color {
        switch self { case .nominal: .neon; case .fair: .amber; default: .hot }
    }
}

extension Battery {
    var icon: String {
        plugged ? "bolt.fill"
            : pct > 85 ? "battery.100percent" : pct > 60 ? "battery.75percent" : pct > 35 ? "battery.50percent"
            : pct > 10 ? "battery.25percent" : "battery.0percent"
    }
    var color: Color { plugged ? .neon : pct <= 20 ? .hot : pct <= 40 ? .amber : .neon }
    var state: String { charging ? "charging" : plugged ? (pct >= 99 ? "charged" : "on hold") : "on battery" }
}

func load(_ f: Double) -> Color { f > 0.85 ? .hot : f > 0.6 ? .amber : .volt }

// MARK: - Pane

struct SysPane: View {
    let st: Stats

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Gauge(icon: "cpu", title: "cpu", value: "\(Int(st.cpu * 100))%", sub: "\(st.cores) cores",
                          color: load(st.cpu)) { Spark(values: st.cpuHist, top: 1, color: load(st.cpu)) }
                    Gauge(icon: "memorychip", title: "memory", value: "\(Int(st.mem * 100))%",
                          sub: "\(fmtBytes(Double(st.memUsed))) / \(fmtBytes(Double(st.memTotal)))",
                          color: load(st.mem)) { Spark(values: st.memHist, top: 1, color: load(st.mem)) }
                    network
                }
                HStack(spacing: 8) {
                    battery
                    disk.frame(width: 150)
                }
            }
            procs.frame(width: 196)
        }
        .onAppear { st.watch(true) }
        .onDisappear { st.watch(false) }
    }

    var network: some View {
        let top = max(64 * 1024, (st.downHist + st.upHist).max() ?? 0)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "network").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.ice)
                Caps(text: "network")
            }
            HStack(spacing: 8) {
                rate("arrow.down", st.down, .ice)
                rate("arrow.up", st.up, .hot)
            }
            Caps(text: "peak \(fmtBytes(top))/s")
            ZStack {
                Spark(values: st.downHist, top: top, color: .ice)
                Spark(values: st.upHist, top: top, color: .hot)
            }
            .frame(height: 30)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .card(.ice)
    }

    func rate(_ icon: String, _ v: Double, _ c: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 9, weight: .heavy)).foregroundStyle(c)
            Text(fmtBytes(v)).font(sans(15, .semibold)).monospacedDigit().contentTransition(.numericText())
        }
        .frame(height: 24)
    }

    @ViewBuilder var battery: some View {
        if let b = st.battery {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: b.icon).font(.system(size: 10, weight: .bold)).foregroundStyle(b.color)
                        .symbolEffect(.pulse, isActive: b.charging)
                    Caps(text: "battery")
                    Spacer()
                    Caps(text: b.state, color: b.color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(b.pct)%").font(sans(20, .semibold)).monospacedDigit().contentTransition(.numericText())
                    if let m = b.mins { Caps(text: mins(m) + (b.charging ? " to full" : " left")) }
                }
                Bar(frac: Double(b.pct) / 100, color: b.color)
                HStack(spacing: 14) {
                    if let c = b.cycles { mini("cycles", "\(c)") }
                    if let h = b.health { mini("health", "\(h)%") }
                    if let t = b.temp { mini("temp", String(format: "%.0f°", t)) }
                    if let w = b.watts { mini("charger", "\(w)W") }
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .card(b.color)
        } else {
            Empty(icon: "bolt.fill", title: "No battery", sub: "on wall power").card()
        }
    }

    var disk: some View {
        let used = 1 - Double(st.diskFree) / Double(max(1, st.diskTotal))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "internaldrive").font(.system(size: 10, weight: .bold)).foregroundStyle(load(used))
                Caps(text: "disk")
            }
            Text(fmtBytes(Double(st.diskFree))).font(sans(20, .semibold)).monospacedDigit()
            Bar(frac: used, color: load(used))
            Caps(text: "free of \(fmtBytes(Double(st.diskTotal)))")
        }
        .padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(load(used))
    }

    var procs: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.volt)
                Caps(text: "top cpu")
                Spacer()
                Caps(text: "mem")
            }
            if st.top.isEmpty {
                Spacer()
            } else {
                ForEach(st.top) { p in
                    HStack(spacing: 6) {
                        Text(p.name).font(sans(11, .medium)).foregroundStyle(Color.fg).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text(String(format: "%.0f%%", p.cpu)).font(mono(10, .bold)).foregroundStyle(load(p.cpu / 100))
                        Text(fmtBytes(Double(p.mem))).font(mono(10)).foregroundStyle(Color.fg3).frame(width: 34, alignment: .trailing)
                    }
                    .help("\(p.name) · pid \(p.id)")
                }
            }
            Spacer(minLength: 0)
            Divider().overlay(Color.white.opacity(0.08))
            HStack(spacing: 14) {
                HStack(spacing: 4) {
                    Image(systemName: "thermometer.medium").font(.system(size: 10, weight: .bold)).foregroundStyle(st.thermal.color)
                    Caps(text: st.thermal.label, color: st.thermal.color)
                }
                .help("macOS thermal pressure")
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    HStack(spacing: 4) {
                        Image(systemName: "clock").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.fg3)
                        Caps(text: "up " + uptime(ProcessInfo.processInfo.systemUptime))
                    }
                }
            }
        }
        .padding(10).frame(maxHeight: .infinity, alignment: .top)
        .card(.volt)
    }

    func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(mono(11, .semibold)).foregroundStyle(Color.fg)
            Caps(text: label)
        }
    }

    func uptime(_ s: Double) -> String {
        let m = Int(s) / 60
        return m >= 1440 ? "\(m / 1440)d \(m / 60 % 24)h" : mins(m)
    }
}

struct Gauge<Chart: View>: View {
    let icon: String, title: String, value: String, sub: String, color: Color
    @ViewBuilder var chart: Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                Caps(text: title)
            }
            Text(value).font(sans(20, .semibold)).monospacedDigit().contentTransition(.numericText()).frame(height: 24)
            Caps(text: sub)
            chart.frame(height: 30)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .card(color)
        .animation(.easeOut(duration: 0.3), value: value)
    }
}

/// Rolling line + fade fill; newest sample sits on the right edge.
struct Spark: View {
    let values: [Double], top: Double, color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(Stats.span - 1)
            let x0 = size.width - step * CGFloat(values.count - 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: x0 + step * CGFloat(i), y: 1 + (size.height - 2) * (1 - CGFloat(min(1, v / max(top, 1e-9)))))
            }
            var line = Path()
            line.addLines(pts)
            var fill = line
            fill.addLine(to: CGPoint(x: pts[pts.count - 1].x, y: size.height))
            fill.addLine(to: CGPoint(x: pts[0].x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.32), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
        }
    }
}

struct Bar: View {
    let frac: Double, color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(color).frame(width: max(4, g.size.width * min(1, max(0, frac))))
                    .shadow(color: color.opacity(0.6), radius: 4)
            }
        }
        .frame(height: 5)
        .animation(spring, value: frac)
    }
}
