// mac2tv CLI: phát màn hình Mac lên Android TV từ Terminal.
import Foundation
import Network

var host = ""
var tvName: String? = nil
var port: UInt16 = 7878
var listOnly = false
var options = StreamOptions()
options.statsInterval = 5
options.muteMacOutput = true

func usage() -> Never {
    print("""
    Cách dùng: mac2tv [ip-tv] [tuỳ chọn]
      (không nhập IP: tự tìm TV đang mở app Mac2TV trong mạng LAN)
      --tv TÊN       chọn TV theo tên khi có nhiều TV
      --port N       cổng TCP trên TV (mặc định 7878)
      --fps N        khung hình/giây (mặc định 60)
      --bitrate N    bitrate Mbps (mặc định 12)
      --width N      chiều rộng video gửi đi (mặc định 1920)
      --display N    chỉ số màn hình (mặc định 0 = màn hình chính)
      --no-audio     không truyền âm thanh
      --keep-mac-audio  vẫn phát tiếng ở loa Mac (mặc định: tạm tắt loa Mac khi phát)
      --list         liệt kê các màn hình
    """)
    exit(1)
}

do {
    var args = Array(CommandLine.arguments.dropFirst())
    func next() -> String { guard !args.isEmpty else { usage() }; return args.removeFirst() }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--port": port = UInt16(next()) ?? 7878
        case "--fps": options.fps = Int(next()) ?? 60
        case "--bitrate": options.bitrate = (Int(next()) ?? 12) * 1_000_000
        case "--width": options.width = Int(next()) ?? 1920
        case "--display": options.display = Int(next()) ?? 0
        case "--list": listOnly = true
        case "--tv": tvName = next()
        case "--no-audio": options.audio = false
        case "--keep-mac-audio": options.muteMacOutput = false
        case "-h", "--help": usage()
        default:
            if a.hasPrefix("-") { usage() }
            host = a
        }
    }
}

// Lần trước bị tắt đột ngột khi loa Mac đang bị tắt tiếng: bật lại.
SystemAudioMuter.recoverIfNeeded()

let permissionHint = "Hãy cấp quyền Screen Recording cho Terminal trong System Settings > Privacy & Security."
var session: StreamSession?
var browser: TVBrowser?

func run(_ endpoint: NWEndpoint) {
    session = StreamSession(endpoint: endpoint, options: options) { event in
        switch event {
        case .connected(let addr): print("✅ Đã kết nối tới TV (\(addr))")
        case .streaming(let desc): print("📺 Đang phát \(desc). Ctrl+C để dừng.")
        case .stats(let fps, let dropped): print(String(format: "   %.0f fps gửi, %d khung bỏ do nghẽn mạng", fps, dropped))
        case .stopped(.user): break
        case .stopped(.permission): print("❌ Không có quyền ghi màn hình. \(permissionHint)"); exit(6)
        case .stopped(.error(let msg)): print("❌ \(msg)"); exit(2)
        }
    }
    session?.start()
}

if listOnly {
    Task {
        do {
            for d in try await listDisplays() { print("[\(d.index)] \(d.name) — \(d.width)x\(d.height)") }
            exit(0)
        } catch {
            print("❌ \(error.localizedDescription)\n\(permissionHint)"); exit(6)
        }
    }
} else if host.isEmpty {
    print("🔎 Đang tìm TV trong mạng LAN…")
    let b = TVBrowser()
    browser = b
    b.onError = { msg in print("⚠️ \(msg)") }
    b.start()
    let started = Date()
    var done = false
    // Chờ ít nhất 1.5s để gom đủ kết quả, tối đa 8s.
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        guard !done else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= 1.5 else { return }
        let matches = b.tvs.filter { tvName == nil || $0.name.localizedCaseInsensitiveContains(tvName!) }
        if matches.isEmpty {
            guard elapsed >= 8 else { return }
            if let tvName, !b.tvs.isEmpty {
                print("❌ Không có TV nào tên chứa \"\(tvName)\". Tìm thấy: \(b.tvs.map(\.name).joined(separator: ", "))")
            } else {
                print("❌ Không tìm thấy TV. Hãy mở app \"Mac2TV\" trên TV (cùng mạng Wi-Fi/LAN), hoặc nhập IP: mac2tv <ip-tv>")
            }
            exit(7)
        }
        done = true
        timer.invalidate()
        b.stop()
        if matches.count > 1 {
            print("ℹ️  Thấy \(matches.count) TV: \(matches.map(\.name).joined(separator: ", ")) — dùng --tv TÊN để chọn")
        }
        print("📡 Chọn TV: \(matches[0].name)")
        run(matches[0].endpoint)
    }
} else {
    print("🔌 Đang kết nối tới \(host):\(port)…")
    run(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
}

// Ctrl+C: báo TV dừng (gói bye) rồi mới thoát.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\n👋 Dừng.")
    session?.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
sigint.resume()
RunLoop.main.run()
