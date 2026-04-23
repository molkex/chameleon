import os.log

enum AppLogger {
    static let app = Logger(subsystem: AppConfig.logSubsystem, category: "app")
    static let tunnel = Logger(subsystem: AppConfig.logSubsystem, category: "tunnel")
    static let network = Logger(subsystem: AppConfig.logSubsystem, category: "network")
}
