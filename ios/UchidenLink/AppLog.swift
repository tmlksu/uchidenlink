import Foundation
import OSLog

/// OSLog wrapper (subsystem = Bundle ID). State transitions and HTTP status
/// codes are .public; anything that could identify a call is kept out or
/// .private. Passwords and tokens are never logged.
/// In DEBUG builds lines are also mirrored to stderr so that
/// `devicectl device process launch --console` captures them reliably.
enum AppLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.tmlksu.uchidenlink"
    static let connection = Logger(subsystem: subsystem, category: "connection")
    static let call = Logger(subsystem: subsystem, category: "call")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let stats = Logger(subsystem: subsystem, category: "stats")
    static let push = Logger(subsystem: subsystem, category: "push")

    private static func mirror(_ category: String, _ message: String) {
        #if DEBUG
        let line = "[uchidenlink][\(category)] \(message)\n"
        FileHandle.standardError.write(Data(line.utf8))
        #endif
    }

    static func connectionEvent(_ message: String) {
        connection.log("\(message, privacy: .public)")
        mirror("connection", message)
    }

    static func callEvent(_ message: String) {
        call.log("\(message, privacy: .public)")
        mirror("call", message)
    }

    static func audioEvent(_ message: String) {
        audio.log("\(message, privacy: .public)")
        mirror("audio", message)
    }

    /// VoIP push (トークンは伏せて出す)。
    static func pushEvent(_ message: String) {
        push.log("\(message, privacy: .public)")
        mirror("push", message)
    }

    /// 通話品質の数値 (`[stats]` / `[autotest]` 行)。番号・表示名は含めない (callId と数値だけ)。
    static func statsEvent(_ message: String) {
        stats.log("\(message, privacy: .public)")
        mirror("stats", message)
    }
}
