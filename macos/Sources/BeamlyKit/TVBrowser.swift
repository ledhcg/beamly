import Foundation
import Network

/// A TV running the Beamly receiver, discovered over DNS-SD.
public struct TV: Hashable, Sendable {
    public let name: String
    public let endpoint: NWEndpoint
}

/// Continuously browses for TVs advertising `BeamlyProtocol.serviceType`.
/// Callbacks are delivered on the main queue.
public final class TVBrowser {
    private var browser: NWBrowser?
    public private(set) var tvs: [TV] = []
    public var onChange: (([TV]) -> Void)?
    public var onError: ((String) -> Void)?

    public init() {}

    public func start() {
        let browser = NWBrowser(for: .bonjour(type: BeamlyProtocol.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let list = Self.uniqueTVs(results.map(\.endpoint))
            DispatchQueue.main.async {
                self?.tvs = list
                self?.onChange?(list)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let message: String?
            switch state {
            case .failed(let error): message = "Cannot search for TVs: \(error.localizedDescription)"
            case .waiting(let error):
                message = "Cannot search for TVs (is Local Network access allowed?): \(error.localizedDescription)"
            default: message = nil
            }
            if let message { DispatchQueue.main.async { self?.onError?(message) } }
        }
        browser.start(queue: DispatchQueue(label: "app.beamly.browser"))
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// One entry per service name (a TV can be reported once per network interface), sorted by name.
    static func uniqueTVs(_ endpoints: [NWEndpoint]) -> [TV] {
        var seen = Set<String>()
        return endpoints.compactMap { endpoint -> TV? in
            guard case let .service(name, _, _, _) = endpoint, seen.insert(name).inserted else { return nil }
            return TV(name: name, endpoint: endpoint)
        }
        .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }
}
