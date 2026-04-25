import Foundation

/// Per-network memory of which VPN leg actually worked last time. Read
/// before the pre-connect race to bias toward a known-good leg; written
/// after `TrafficHealthMonitor`'s probe confirms real traffic flow.
///
/// Storage: a single UserDefaults dictionary keyed by
/// `"<fingerprint>::<countryCode>"`. Bounded by trimming entries when
/// the dict exceeds `maxEntries` — LRU-by-write-time. We don't expect
/// the table to grow large in practice (a user has on the order of 5-15
/// distinct networks × 5 countries), but the cap is a hedge against a
/// runaway scenario where the SSID changes constantly (captive portals).
struct LastWorkingLegStore {
    private static let storageKey = "lastWorkingLegStore.v1"
    private static let maxEntries = 200

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns the leaf tag last confirmed working for the given country
    /// on the given network, or nil if we have no memory.
    func get(fingerprint: String, country: String) -> String? {
        let key = compositeKey(fingerprint: fingerprint, country: country)
        let dict = loadRaw()
        return (dict[key] as? [String: Any])?["leg"] as? String
    }

    /// Records that the given leg worked for the given country on the
    /// given network. Writes are debounced trivially: if the same value
    /// is already stored we skip the disk write.
    func set(fingerprint: String, country: String, leg: String) {
        let key = compositeKey(fingerprint: fingerprint, country: country)
        var dict = loadRaw()
        if let existing = dict[key] as? [String: Any], existing["leg"] as? String == leg {
            // Touch lastUsed but only every minute to avoid write thrash.
            let last = (existing["t"] as? TimeInterval) ?? 0
            if Date().timeIntervalSince1970 - last < 60 {
                return
            }
        }
        dict[key] = ["leg": leg, "t": Date().timeIntervalSince1970]
        if dict.count > Self.maxEntries {
            dict = trimToCap(dict)
        }
        defaults.set(dict, forKey: Self.storageKey)
    }

    /// Forget a single (fingerprint, country) entry — used after a probe
    /// fails so we don't keep biasing toward a now-broken leg.
    func forget(fingerprint: String, country: String) {
        let key = compositeKey(fingerprint: fingerprint, country: country)
        var dict = loadRaw()
        guard dict[key] != nil else { return }
        dict.removeValue(forKey: key)
        defaults.set(dict, forKey: Self.storageKey)
    }

    /// Test-only.
    func clear() {
        defaults.removeObject(forKey: Self.storageKey)
    }

    private func loadRaw() -> [String: Any] {
        defaults.dictionary(forKey: Self.storageKey) ?? [:]
    }

    private func compositeKey(fingerprint: String, country: String) -> String {
        "\(fingerprint)::\(country)"
    }

    private func trimToCap(_ dict: [String: Any]) -> [String: Any] {
        let entries = dict.compactMap { (key, value) -> (String, TimeInterval)? in
            guard let entry = value as? [String: Any], let t = entry["t"] as? TimeInterval else { return nil }
            return (key, t)
        }
        let sorted = entries.sorted(by: { $0.1 > $1.1 })
        let keep = Set(sorted.prefix(Self.maxEntries).map(\.0))
        return dict.filter { keep.contains($0.key) }
    }
}
