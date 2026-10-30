import AppKit
import IOKit.ps

// Mac vitals straight from the kernel (no `top`/`ps` subprocesses):
//  CPU  host_statistics(HOST_CPU_LOAD_INFO) tick deltas
//  RAM  vm_statistics64 → same "Memory Used" Activity Monitor shows (app + wired + compressed)
//  BAT  IOPowerSources

struct MacStats {
    var cpu: Double = 0            // 0...1
    var ramUsed: Double = 0        // bytes
    var ramTotal: Double = 0       // bytes
    var pressure: Int = 1          // 1 normal, 2 warn, 4 critical
    var battery: Double? = nil     // 0...1, nil on desktop Macs
    var charging = false
    var onAC = false
    var minutesLeft: Int? = nil
    var thermal: ProcessInfo.ThermalState = .nominal

    var ramFrac: Double { ramTotal > 0 ? ramUsed / ramTotal : 0 }
}

final class StatsSampler {
    private var lastTicks: (user: UInt64, sys: UInt64, idle: UInt64, nice: UInt64)?
    private(set) var stats = MacStats()

    func sample() -> MacStats {
        stats.cpu = sampleCPU() ?? stats.cpu
        sampleRAM()
        sampleBattery()
        stats.thermal = ProcessInfo.processInfo.thermalState
        return stats
    }

    private func sampleCPU() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = (user: UInt64(info.cpu_ticks.0), sys: UInt64(info.cpu_ticks.1),
                 idle: UInt64(info.cpu_ticks.2), nice: UInt64(info.cpu_ticks.3))
        defer { lastTicks = t }
        guard let p = lastTicks else { return nil }
        let busy = Double((t.user - p.user) + (t.sys - p.sys) + (t.nice - p.nice))
        let total = busy + Double(t.idle - p.idle)
        return total > 0 ? busy / total : nil
    }

    private func sampleRAM() {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return }
        let page = Double(vm_kernel_page_size)
        // Activity Monitor's "Memory Used" = physical − (free − speculative + file-backed).
        // This includes the RAM the system reserves for firmware/GPU (hw.memsize − hw.memsize_usable),
        // which App+Wired+Compressed alone misses (~0.75 GB on this Mac). Matches fastfetch, which
        // was checked against Activity Monitor.
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        let reclaimable = (Double(vm.free_count) - Double(vm.speculative_count) + Double(vm.external_page_count)) * page
        stats.ramUsed = max(0, total - reclaimable)
        stats.ramTotal = total
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 { stats.pressure = Int(level) }
    }

    private func sampleBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Double ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Double ?? 100
            stats.battery = max > 0 ? cur / max : nil
            stats.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            stats.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let key = stats.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let m = d[key] as? Int, m > 0 { stats.minutesLeft = m } else { stats.minutesLeft = nil }
        }
    }
}

// MARK: - chip

final class StatsChip: Chip {
    var stats = MacStats() { didSet { relayout() } }
    private struct Col { var value: NSAttributedString; var label: NSAttributedString; var frac: Double; var color: NSColor }
    private var cols: [Col] = []

    override init() { super.init(); relayout() }
    required init?(coder: NSCoder) { fatalError() }

    private func level(_ f: Double, warn: Double, crit: Double) -> NSColor {
        f >= crit ? .systemRed : (f >= warn ? .systemOrange : NSColor(white: 0.92, alpha: 1))
    }

    private func relayout() {
        var c: [Col] = []
        let cpuColor = level(stats.cpu, warn: 0.7, crit: 0.9)
        c.append(Col(value: attr(pct(stats.cpu), 12, .bold, cpuColor, mono: true),
                     label: attr(stats.thermal.rawValue >= 2 ? "cpu hot" : "cpu", 9, .medium, stats.thermal.rawValue >= 2 ? .systemOrange : dimText),
                     frac: stats.cpu, color: cpuColor))

        let gb = stats.ramUsed / 1_073_741_824
        let ramColor: NSColor = stats.pressure >= 4 ? .systemRed : (stats.pressure >= 2 ? .systemOrange : NSColor(white: 0.92, alpha: 1))
        c.append(Col(value: attr(String(format: "%.1fG", gb), 12, .bold, ramColor, mono: true),
                     label: attr("ram", 9, .medium, dimText),
                     frac: stats.ramFrac, color: ramColor))

        if let b = stats.battery {
            let bc: NSColor = stats.charging || stats.onAC ? workingGreen : (b <= 0.1 ? .systemRed : (b <= 0.2 ? .systemOrange : NSColor(white: 0.92, alpha: 1)))
            var lab = stats.charging ? "charging" : (stats.onAC ? "plugged" : "battery")
            if let m = stats.minutesLeft, !stats.onAC || stats.charging { lab = "\(stats.charging ? "⚡" : "")\(m / 60)h\(String(format: "%02d", m % 60))" }
            c.append(Col(value: attr(pct(b), 12, .bold, bc, mono: true), label: attr(lab, 9, .medium, dimText), frac: b, color: bc))
        }
        cols = c
        let w = cols.reduce(CGFloat(6)) { $0 + 4 + 4 + max($1.value.size().width, $1.label.size().width) + 5 }
        setWidth(w)
    }

    override func drawContent(_ r: NSRect) {
        var x = r.minX + 6
        for col in cols {
            // vertical mini meter
            let track = NSRect(x: x, y: r.midY - 9, width: 4, height: 18)
            trackColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
            let h = max(2, track.height * CGFloat(min(1, col.frac)))
            col.color.setFill()
            NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: 4, height: h), xRadius: 2, yRadius: 2).fill()
            let tx = x + 4 + 4
            drawTwoLines(col.value, col.label, x: tx, in: r)
            x = tx + max(col.value.size().width, col.label.size().width) + 5
        }
    }
}
