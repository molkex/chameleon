import os.log

enum AppLogger {
    static let app = Logger(subsystem: "com.madfrog.vpn", category: "app")
    static let tunnel = Logger(subsystem: "com.madfrog.vpn", category: "tunnel")
    static let network = Logger(subsystem: "com.madfrog.vpn", category: "network")
}
