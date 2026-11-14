// `mac-cleaner doctor`
import CleanerCore
import Foundation

enum DoctorCommand {
    static func run(_ args: ParsedArguments, _ ctx: Context) async throws -> Int32 {
        let probe = ctx.probe
        let disk = ctx.engine.diskInfo()
        let fda = ctx.engine.hasFullDiskAccess()
        let apfs = probe.apfsLayout()
        let snapshots = probe.localSnapshots()
        let report = DoctorReport(
            cliVersion: cliVersion, macOSVersion: probe.osVersion(), architecture: probe.architecture(),
            disk: DiskReport(disk), fullDiskAccess: fda, tools: probe.detectedTools(home: ctx.home),
            apfsVolumes: apfs?.volumes ?? [], apfsContainerFreeBytes: apfs?.containerFreeBytes,
            localSnapshots: snapshots ?? [], swapBytes: probe.swapBytes())
        try Task.checkCancellation()

        if ctx.json {
            ctx.emit(report)
            return ExitCode.ok
        }
        let s = ctx.style
        ctx.out(s.bold("Mac Cleaner doctor") + s.dim("  mac-cleaner \(cliVersion), macOS \(report.macOSVersion), \(report.architecture)"))

        ctx.out()
        ctx.out(s.bold("Disk numbers"))
        ctx.out("  Total            \(formatBytes(disk.totalBytes).leftPadded(10))")
        ctx.out("  Free now         \(formatBytes(disk.freeBytes).leftPadded(10))   what is really free (df)")
        ctx.out("  Free + purgeable \(formatBytes(disk.availableWithPurgeableBytes).leftPadded(10))   what Finder calls \"available\"")
        ctx.out(s.dim("  Purgeable space (\(formatBytes(disk.purgeableBytes))) is cache and snapshot data macOS gives back on demand. It is"))
        ctx.out(s.dim("  not free yet: deleting files may not raise \"Free now\" immediately, and Finder's number can be optimistic."))

        ctx.out()
        ctx.out(s.bold("Full Disk Access"))
        if fda {
            ctx.out("  " + s.green("granted") + s.dim("  - sizes and deletions can reach protected folders"))
        } else {
            ctx.out("  " + s.yellow("not granted") + s.dim("  - some folders are hidden from this process; sizes may be too small"))
            ctx.out(s.dim("  Grant it to your terminal app: System Settings > Privacy & Security > Full Disk Access."))
        }

        ctx.out()
        ctx.out(s.bold("Optional tools found") + s.dim("  (their caches get cleanup categories)"))
        if report.tools.isEmpty {
            ctx.out("  none")
        } else {
            for t in report.tools { ctx.out("  " + t.name.padding(toLength: 12, withPad: " ", startingAt: 0) + s.dim(t.path)) }
        }

        ctx.out()
        ctx.out(s.bold("APFS volumes sharing this disk") + s.dim("  (they all draw from the same free space)"))
        if apfs == nil {
            ctx.out(s.dim("  (could not read the APFS layout)"))
        } else {
            for v in report.apfsVolumes {
                let role = v.roles.isEmpty ? "-" : v.roles.joined(separator: "/")
                ctx.out("  \(formatBytes(v.bytesInUse).leftPadded(10))  \(v.name) " + s.dim("(\(role))"))
            }
            if let free = report.apfsContainerFreeBytes {
                ctx.out("  \(formatBytes(free).leftPadded(10))  " + s.green("unallocated"))
            }
        }

        ctx.out()
        ctx.out(s.bold("Local snapshots") + s.dim("  (keep deleted data on disk until they are removed)"))
        if snapshots == nil {
            ctx.out(s.dim("  (could not run tmutil)"))
        } else if report.localSnapshots.isEmpty {
            ctx.out("  none")
        } else {
            for sn in report.localSnapshots {
                let hint = sn.kind == "macOS update" ? "goes away once the pending update is installed"
                    : (sn.kind == "Time Machine" ? "removable from the Cleanup screen / `mac-cleaner clean snapshots`" : "")
                ctx.out("  \(truncate(sn.name, to: 60))  " + s.dim("\(sn.kind) \(hint)"))
            }
        }

        if let swap = report.swapBytes {
            ctx.out()
            ctx.out(s.bold("Swap / sleep image") + "  \(formatBytes(swap))" + s.dim("  (shrinks after a reboot; grows when RAM is exhausted)"))
        }
        return ExitCode.ok
    }
}
