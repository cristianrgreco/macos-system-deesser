import Foundation
import OSLog

/// Centralized `os.Logger` categories. These are used only on the control/UI
/// threads. The real-time audio callback must never log (see spec §10.3), so no
/// logger is ever passed into the C++/Obj-C++ render path.
enum Log {
    private static let subsystem = "local.TeamsDeEsser"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}
