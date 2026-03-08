import Foundation
import ToasttyCLIKit

exit(ToasttyCLI.run(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment))
