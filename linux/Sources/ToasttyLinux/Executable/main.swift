import Foundation
import ToasttyLinuxUI

let status = MainActor.assumeIsolated { ToasttyLinuxMain.run(arguments: CommandLine.arguments) }
exit(status)
