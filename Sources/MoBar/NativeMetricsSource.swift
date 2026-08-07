import Darwin
import Foundation

/// 不依赖 mole，直接读内核：
/// - CPU：host_statistics(HOST_CPU_LOAD_INFO) 的 tick 增量
/// - 内存：host_statistics64(HOST_VM_INFO64)
/// - 网速：getifaddrs 的 AF_LINK if_data 字节数增量
///
/// 口径经过和 mole 并排比对校准，切换数据源时数字不会跳。
final class NativeMetricsSource: MetricsSource {
    var onSample: ((Sample) -> Void)?
    var onFailure: ((String) -> Void)?
    let displayName = Settings.SourceKind.native.displayName

    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "fit.mole.mobar.native")
    private var timer: DispatchSourceTimer?

    private var previousCPU: CPUTicks?
    private var previousNet: [String: NetCounters] = [:]
    private var previousTime: TimeInterval?

    /// 睡眠唤醒后时间跨度会很大，计数器却没同步增长，算出来是假尖峰。
    /// 超过这个间隔就丢弃这一轮，只重置基线。
    private static let maxElapsed: TimeInterval = 60

    init(interval: TimeInterval = 2) {
        self.interval = interval
    }

    func start() {
        queue.async {
            guard self.timer == nil else { return }
            self.resetBaseline()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // 首帧提前到 0.5 秒，不然启动后要空等一个完整周期才有数
            timer.schedule(deadline: .now() + 0.5, repeating: self.interval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
        }
    }

    func restart() {
        queue.async { self.resetBaseline() }
    }

    private func resetBaseline() {
        previousCPU = Self.readCPUTicks()
        previousNet = Self.readNetCounters()
        previousTime = ProcessInfo.processInfo.systemUptime
    }

    private func tick() {
        // systemUptime 不计睡眠时间，和内核计数器的推进节奏一致
        let now = ProcessInfo.processInfo.systemUptime
        guard let lastTime = previousTime else { resetBaseline(); return }
        let elapsed = now - lastTime
        previousTime = now

        guard elapsed > 0, elapsed < Self.maxElapsed else {
            resetBaseline()
            return
        }

        guard let memory = Self.readMemoryPercent() else {
            report("读取内存失败")
            return
        }

        let cpu = Self.readCPUTicks()
        var cpuPercent = 0.0
        if let current = cpu, let previous = previousCPU {
            let busy = current.busy &- previous.busy
            let total = current.total &- previous.total
            if total > 0 { cpuPercent = min(Double(busy) / Double(total) * 100, 100) }
        }
        previousCPU = cpu ?? previousCPU

        let net = Self.readNetCounters()
        var rxBytes: UInt64 = 0
        var txBytes: UInt64 = 0
        for (name, current) in net {
            guard let previous = previousNet[name] else { continue }
            // ifi_ibytes 是 32 位会回绕，&- 正好处理；但网卡重连会清零，
            // 这时 &- 出来是个天文数字，超过 2GB 直接丢掉这张卡这一轮。
            let rx = UInt64(current.rx &- previous.rx)
            let tx = UInt64(current.tx &- previous.tx)
            if rx < 1 << 31 { rxBytes += rx }
            if tx < 1 << 31 { txBytes += tx }
        }
        previousNet = net

        let toMBs = 1.0 / (elapsed * 1_048_576)
        let sample = Sample(
            cpuPercent: cpuPercent,
            memPercent: memory,
            rxMBs: Double(rxBytes) * toMBs,
            txMBs: Double(txBytes) * toMBs
        )
        debugLog(String(format: "cpu=%.1f mem=%.1f rx=%.4f tx=%.4f dt=%.2fs",
                        sample.cpuPercent, sample.memPercent, sample.rxMBs, sample.txMBs, elapsed))
        DispatchQueue.main.async { self.onSample?(sample) }
    }

    private func report(_ message: String) {
        debugLog("failure: \(message)")
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["MOBAR_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[mobar/native] \(message)\n".utf8))
    }

    // MARK: - CPU

    private struct CPUTicks {
        let busy: UInt32
        let total: UInt32
    }

    private static func readCPUTicks() -> CPUTicks? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), host_flavor_t(HOST_CPU_LOAD_INFO), $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks 顺序：user, system, idle, nice
        let user = info.cpu_ticks.0, system = info.cpu_ticks.1
        let idle = info.cpu_ticks.2, nice = info.cpu_ticks.3
        return CPUTicks(busy: user &+ system &+ nice, total: user &+ system &+ nice &+ idle)
    }

    // MARK: - 内存

    /// 口径对齐 mole（gopsutil）：used = total - free - inactive。
    /// 想要 Activity Monitor 的「已用内存」语义，换成 (active + wired + compressed)，
    /// 本机实测两者差约 2.7 个百分点。
    private static func readMemoryPercent() -> Double? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var stats = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), host_flavor_t(HOST_VM_INFO64), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let pageSize = UInt64(vm_kernel_page_size)
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0, pageSize > 0 else { return nil }

        let available = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
        let used = total > available ? total - available : 0
        return Double(used) / Double(total) * 100
    }

    // MARK: - 网速

    private struct NetCounters {
        let rx: UInt32
        let tx: UInt32
    }

    /// 只统计物理网卡（en/eth/bridge）且已分到 IP 的接口。
    /// 不能按「有 IP」一刀切：本机 utun0-3 是 VPN 隧道，也有 IP，
    /// 隧道流量同时穿过 en0，全算进来就翻倍了。
    private static func readNetCounters() -> [String: NetCounters] {
        var result: [String: NetCounters] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var physical = Set<String>()
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("bridge") else { continue }
            guard let address = pointer.pointee.ifa_addr else { continue }
            let family = address.pointee.sa_family
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                physical.insert(name)
            }
        }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let raw = pointer.pointee.ifa_data else { continue }
            let name = String(cString: pointer.pointee.ifa_name)
            guard physical.contains(name) else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self)
            result[name] = NetCounters(rx: data.pointee.ifi_ibytes, tx: data.pointee.ifi_obytes)
        }
        return result
    }
}
