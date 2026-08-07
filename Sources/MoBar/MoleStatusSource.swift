import Foundation

/// `status-go -watch` 每行输出的 JSON，只声明用得到的字段。
/// 解码时开启 convertFromSnakeCase，所以这里用驼峰对应
/// cpu.usage / memory.used_percent / network[].rx_rate_mbs。
private struct StatusPayload: Decodable {
    struct CPU: Decodable {
        let usage: Double
    }

    struct Memory: Decodable {
        let usedPercent: Double
    }

    struct Interface: Decodable {
        let name: String
        let rxRateMbs: Double
        let txRateMbs: Double
        let ip: String?

        /// 有 IP 的接口才是当前真正在跑流量的那张网卡。
        var isActive: Bool { !(ip ?? "").isEmpty }
    }

    let cpu: CPU
    let memory: Memory
    let network: [Interface]

    /// 汇总网速：优先只算有 IP 的接口，全都没 IP 时退回全部接口求和。
    /// 不写死 en0，换 Wi-Fi / 有线 / 手机热点都能跟上。
    func toSample() -> Sample {
        let active = network.filter { $0.isActive }
        let pool = active.isEmpty ? network : active
        return Sample(
            cpuPercent: cpu.usage,
            memPercent: memory.usedPercent,
            rxMBs: pool.reduce(0) { $0 + $1.rxRateMbs },
            txMBs: pool.reduce(0) { $0 + $1.txRateMbs }
        )
    }
}

/// 常驻一个 `status-go -watch -interval 2s` 子进程，按行读 NDJSON。
///
/// 为什么不每 2 秒跑一次 `mo status --json`：单次实测 real 1.38s、CPU 1.4s，
/// 2 秒一轮等于常驻吃掉大半个核心，采样延迟也快追上刷新周期了。
///
/// 为什么直接调 Go 二进制而不是 `mo status --watch`：外面那层 shell 包装在非 TTY
/// 环境下会挂住；顺带也避开 GUI 进程不继承 shell PATH 的问题。
final class MoleStatusSource: MetricsSource {
    var onSample: ((Sample) -> Void)?
    var onFailure: ((String) -> Void)?
    let displayName = Settings.SourceKind.mole.displayName

    private let interval: String
    private let queue = DispatchQueue(label: "fit.mole.mobar.reader")
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private var process: Process?
    private var buffer = Data()
    private var stopping = false
    private var generation = 0

    /// 单行 JSON 实测约 2.9KB，留足余量；超过就认为流坏了，丢弃重新对齐。
    private static let maxBufferBytes = 1 << 20

    /// 用 opt 符号链接而不是 Cellar 里的版本号路径，mole 升级后不会失效。
    private static let candidatePaths: [String] = {
        var paths: [String] = []
        if let override = ProcessInfo.processInfo.environment["MOBAR_STATUS_BIN"], !override.isEmpty {
            paths.append(override)
        }
        paths.append("/opt/homebrew/opt/mole/libexec/bin/status-go")
        paths.append("/usr/local/opt/mole/libexec/bin/status-go")
        return paths
    }()

    init(interval: String = "2s") {
        self.interval = interval
    }

    func start() {
        queue.async {
            self.stopping = false
            guard self.process == nil else { return }
            self.launch()
        }
    }

    func stop() {
        queue.async {
            self.stopping = true
            self.generation += 1
            self.process?.terminate()
            self.process = nil
        }
    }

    /// 数据源卡死时的人工急救，菜单里挂着这一项。
    func restart() {
        queue.async {
            self.stopping = true
            self.generation += 1
            self.process?.terminate()
            self.process = nil
            self.buffer.removeAll()
            self.queue.asyncAfter(deadline: .now() + 0.3) {
                self.stopping = false
                self.launch()
            }
        }
    }

    // MARK: - 子进程

    private func launch() {
        guard process == nil, !stopping else { return }

        let fm = FileManager.default
        guard let binary = Self.candidatePaths.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            report(failure: "找不到 status-go，先 brew install mole")
            return
        }

        generation += 1
        let currentGeneration = generation

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["-watch", "-interval", interval]
        proc.standardInput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        let readHandle = pipe.fileHandleForReading

        readHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self.queue.async { self.ingest(chunk, generation: currentGeneration) }
        }

        proc.terminationHandler = { [weak self] _ in
            readHandle.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                guard currentGeneration == self.generation else { return }
                self.process = nil
                guard !self.stopping else { return }
                // mole 升级、被 kill、自己崩了都会走到这儿。延迟 2 秒重开，
                // 不然菜单栏会永远静止在最后一帧。
                self.queue.asyncAfter(deadline: .now() + 2) {
                    guard currentGeneration == self.generation, !self.stopping else { return }
                    self.launch()
                }
            }
        }

        do {
            try proc.run()
            process = proc
            buffer.removeAll()
            debugLog("launched \(binary) -watch -interval \(interval)")
        } catch {
            process = nil
            report(failure: "启动 status-go 失败：\(error.localizedDescription)")
            queue.asyncAfter(deadline: .now() + 5) {
                guard currentGeneration == self.generation, !self.stopping else { return }
                self.launch()
            }
        }
    }

    // MARK: - 按行解码

    private func ingest(_ chunk: Data, generation: Int) {
        guard generation == self.generation else { return }
        buffer.append(chunk)

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            decode(Data(line))
        }

        if buffer.count > Self.maxBufferBytes {
            debugLog("buffer overflow, dropping \(buffer.count) bytes")
            buffer.removeAll()
        }
    }

    private func decode(_ line: Data) {
        guard let sample = try? decoder.decode(StatusPayload.self, from: line).toSample() else {
            // mole 的 JSON 不是公开 API，字段真变了就会落到这里。
            debugLog("decode failed")
            return
        }
        debugLog(String(
            format: "cpu=%.1f mem=%.1f rx=%.4f tx=%.4f",
            sample.cpuPercent, sample.memPercent, sample.rxMBs, sample.txMBs
        ))
        DispatchQueue.main.async { self.onSample?(sample) }
    }

    private func report(failure message: String) {
        debugLog("failure: \(message)")
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["MOBAR_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[mobar/mole] \(message)\n".utf8))
    }
}
