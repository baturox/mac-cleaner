import CleanerCore
import Dispatch
import Foundation

// Ctrl-C cancels the running task. A deletion that is in flight stops at the next entry and writes its outcome
// to the audit log; the process waits for that write (bounded) before it exits. A second Ctrl-C exits right
// away: the operation's "started" record is then all the log has, and it is shown as interrupted.
signal(SIGINT, SIG_IGN)
signal(SIGPIPE, SIG_IGN)

let console = StandardConsole()
let rootTask = Task {
    let arguments = Array(CommandLine.arguments.dropFirst())
    // Deletions are logged with the client that asked for them.
    let client: AuditClient = commandName(in: arguments) == "mcp" ? .mcp : .cli
    let code = await runCLI(arguments: arguments,
                            engine: LiveEngine(client: client, appVersion: cliVersion), console: console, settingsStore: .standard)
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
        // Off the main queue, so a second Ctrl-C is still handled while this waits.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if AuditActivity.inFlight > 0 {
                console.err("Waiting for the running deletion to record its outcome…")
                if !AuditActivity.waitUntilIdle(timeout: 20) {
                    console.err("Still running; exiting. The history will show this operation as interrupted.")
                }
            }
            console.err("Cancelled.")
            exit(ExitCode.cancelled)
        }
    } else {
        exit(ExitCode.cancelled)
    }
}
sigint.resume()
dispatchMain()
