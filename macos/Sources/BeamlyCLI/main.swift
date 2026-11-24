// beamly: mirror the Mac's screen and sound to an Android TV running the Beamly receiver.
import BeamlyKit
import Foundation
import Network

// Exit codes
let exitUsage: Int32 = 1
let exitStreamError: Int32 = 2
let exitPermission: Int32 = 6
let exitNoTV: Int32 = 7

var host = ""
var tvName: String?
var port = BeamlyProtocol.defaultPort
var listOnly = false
var options = StreamOptions()
options.statsInterval = 5
options.muteMacOutput = true

func usage() -> Never {
    print(
        """
        Usage: beamly [tv-address] [options]

        Without an address, beamly finds a TV running Beamly on the local network.

        Options:
          --tv NAME           Pick a TV by name when several are found
          --port N            TCP port on the TV (default \(BeamlyProtocol.defaultPort))
          --fps N             Frames per second (default 60)
          --bitrate N         Video bitrate in Mbps (default 12)
          --width N           Width of the video sent to the TV (default 1920)
          --display N         Display index (default 0 = main display; see --list)
          --no-audio          Do not send audio
          --keep-mac-audio    Keep playing sound on the Mac (default: sound plays on the TV only)
          --list              List displays and exit
          -h, --help          Show this help
        """)
    exit(exitUsage)
}

do {
    var args = Array(CommandLine.arguments.dropFirst())
    func next() -> String {
        guard !args.isEmpty else { usage() }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--port": port = UInt16(next()) ?? BeamlyProtocol.defaultPort
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
            if arg.hasPrefix("-") { usage() }
            host = arg
        }
    }
}

// Undo an output-device mute left behind by an older version that exited unexpectedly.
LegacyMuteRecovery.run()

let permissionHint =
    "Allow Screen Recording (and System Audio Recording) for your terminal in System Settings > Privacy & Security."
var session: StreamSession?
var browser: TVBrowser?

func run(_ endpoint: NWEndpoint) {
    session = StreamSession(endpoint: endpoint, options: options) { event in
        switch event {
        case .connected(let address):
            print("Connected to the TV (\(address))")
        case .streaming(let description):
            print("Streaming \(description). Press Ctrl+C to stop.")
        case .stats(let fps, let dropped):
            print(String(format: "  %.0f fps sent, %d frames dropped (network congestion)", fps, dropped))
        case .stopped(.user):
            break
        case .stopped(.permission):
            print("Error: Screen Recording permission is missing. \(permissionHint)")
            exit(exitPermission)
        case .stopped(.error(let message)):
            print("Error: \(message)")
            exit(exitStreamError)
        }
    }
    session?.start()
}

if listOnly {
    Task {
        do {
            for display in try await listDisplays() {
                print("[\(display.index)] \(display.name) — \(display.width)x\(display.height)")
            }
            exit(0)
        } catch {
            print("Error: \(error.localizedDescription)\n\(permissionHint)")
            exit(exitPermission)
        }
    }
} else if host.isEmpty {
    print("Searching for TVs on the local network…")
    let tvBrowser = TVBrowser()
    browser = tvBrowser
    tvBrowser.onError = { message in print("Warning: \(message)") }
    tvBrowser.start()
    let started = Date()
    var done = false
    // Collect results for at least 1.5 s, give up after 8 s.
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        guard !done else { return }
        let elapsed = Date().timeIntervalSince(started)
        guard elapsed >= 1.5 else { return }
        let matches = tvBrowser.tvs.filter { tv in tvName.map { tv.name.localizedCaseInsensitiveContains($0) } ?? true }
        if matches.isEmpty {
            guard elapsed >= 8 else { return }
            if let tvName, !tvBrowser.tvs.isEmpty {
                let found = tvBrowser.tvs.map(\.name).joined(separator: ", ")
                print("Error: no TV name contains \"\(tvName)\". Found: \(found)")
            } else {
                print(
                    "Error: no TV found. Open Beamly on the TV (same Wi-Fi/LAN as this Mac) or pass its address: beamly <tv-address>"
                )
            }
            exit(exitNoTV)
        }
        done = true
        timer.invalidate()
        tvBrowser.stop()
        if matches.count > 1 {
            print(
                "Found \(matches.count) TVs: \(matches.map(\.name).joined(separator: ", ")). Use --tv NAME to choose.")
        }
        print("Using TV: \(matches[0].name)")
        run(matches[0].endpoint)
    }
} else {
    print("Connecting to \(host):\(port)…")
    guard let nwPort = NWEndpoint.Port(rawValue: port) else { usage() }
    run(.hostPort(host: NWEndpoint.Host(host), port: nwPort))
}

// Ctrl+C: tell the TV we are stopping (BYE) before exiting.
signal(SIGINT, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    print("\nStopping.")
    session?.stop()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
}
sigint.resume()
RunLoop.main.run()
