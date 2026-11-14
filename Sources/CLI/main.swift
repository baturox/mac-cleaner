import CleanerCore
import Dispatch
import Foundation

// Ctrl-C cancels the running task; a second Ctrl-C (or a stuck task) exits right away.
signal(SIGINT, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

let console = StandardConsole()
let rootTask = Task {
    let code = await runCLI(arguments: Array(CommandLine.arguments.dropFirst()),
                            engine: LiveEngine(), console: console, settingsStore: .standard)
    exit(code)
}

nonisolated(unsafe) var interruptCount = 0
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler {
    interruptCount += 1
    if console.stderrIsTTY { console.errRaw("\r\u{1B}[2K") }
    if interruptCount == 1 {
        console.err("Interrupted - cancelling (press Ctrl-C again to quit now)…")
        rootTask.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            console.err("Cancelled.")
            exit(ExitCode.cancelled)
        }
    } else {
        exit(ExitCode.cancelled)
    }
}
sigint.resume()
dispatchMain()
