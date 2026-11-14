// PLACEHOLDER — replaced by the real command-line tool.
import CleanerCore
import Foundation

let info = LiveEngine().diskInfo()
print("free: \(info.freeBytes) of \(info.totalBytes)")
