import SwiftUI
import AppKit
import CleanerCore

/// The "Software Update" window. A window of its own (not a sheet) so it can open whenever a check finishes,
/// also while a sheet of the main window is open or the main window is closed.
@MainActor
final class UpdateWindow: NSObject, NSWindowDelegate {
    private static var shared: UpdateWindow?
    private var window: NSWindow?
    private weak var model: UpdateModel?

    static func show(model: UpdateModel) {
        let controller = shared ?? UpdateWindow()
        shared = controller
        controller.model = model
        controller.present(model)
    }

    static func close() { shared?.window?.close() }

    private func present(_ model: UpdateModel) {
        if window == nil {
            let host = NSHostingController(rootView: UpdateView(model: model))
            let w = NSWindow(contentViewController: host)
            w.title = "Software Update"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Not while the new app is being swapped in.
        if case .installing = model?.phase { return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
        model?.windowClosed()
    }
}

struct UpdateView: View {
    var model: UpdateModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .idle: EmptyView()
            case .checking: checking
            case .available(let offer): available(offer)
            case .waitingForClean(let offer): waiting(offer)
            case .working(let offer, let stage): working(offer, stage)
            case .installing(let offer): installing(offer)
            case .upToDate(let v):
                result(symbol: "checkmark.circle.fill", tint: .green, title: "You're up to date",
                       message: "Mac Cleaner \(v) is the newest version.")
            case .unavailable(let message):
                result(symbol: "info.circle.fill", tint: .secondary, title: "Updates are not available", message: message)
            case .failed(let message, let manual):
                result(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "The update did not happen",
                       message: message, manual: manual)
            case .updated(let v):
                result(symbol: "checkmark.circle.fill", tint: .green, title: "Updated to \(v)",
                       message: "Mac Cleaner is now version \(v).")
            }
        }
        .padding(20)
        .frame(width: 500)
        .animation(nil, value: model.phase)
    }

    // MARK: Pieces

    private var icon: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable().frame(width: 56, height: 56)
            .accessibilityHidden(true)
    }

    private func header(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var checking: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
            }
            HStack { Spacer(); Button("Cancel") { model.close() } }
        }
    }

    private func available(_ offer: UpdateOffer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("A new version of Mac Cleaner is available",
                   "Version \(offer.version) is ready. You have \(model.currentVersion).")
            HStack(spacing: 8) {
                Text(model.currentVersion).foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                Text(offer.version.description).fontWeight(.semibold)
            }
            .font(.callout).monospacedDigit()
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("From version \(model.currentVersion) to \(offer.version.description)")

            VStack(alignment: .leading, spacing: 6) {
                Text("What's new").font(.headline)
                NotesView(notes: offer.notes)
            }
            Text("The update is downloaded from GitHub, checked against its published checksum and the developer's signature and notarization, and only then installed. Mac Cleaner restarts to finish.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Skip This Version") { model.skipThisVersion() }
                Spacer()
                Button("Later") { model.later() }
                Button("Install Update") { model.install() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func waiting(_ offer: UpdateOffer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Waiting for the clean to finish", "Version \(offer.version) installs when nothing is being deleted.")
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("A clean is running. It is never interrupted by an update.").font(.callout)
            }
            HStack { Spacer(); Button("Cancel") { model.cancelInstall() } }
        }
    }

    private func working(_ offer: UpdateOffer, _ stage: UpdateStage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Installing Mac Cleaner \(offer.version)", "Mac Cleaner restarts when this is done.")
            VStack(alignment: .leading, spacing: 6) {
                switch stage {
                case .downloading(let got, let total):
                    ProgressView(value: Double(got), total: Double(max(total, 1)))
                    Text("Downloading… \(Fmt.bytes(got)) of \(Fmt.bytes(total))")
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                case .checking:
                    ProgressView().progressViewStyle(.linear)
                    Text("Reading the release…").font(.callout).foregroundStyle(.secondary)
                case .verifyingDownload:
                    ProgressView().progressViewStyle(.linear)
                    Text("Checking the download against its published checksum…").font(.callout).foregroundStyle(.secondary)
                case .unpacking:
                    ProgressView().progressViewStyle(.linear)
                    Text("Unpacking…").font(.callout).foregroundStyle(.secondary)
                case .verifyingApp:
                    ProgressView().progressViewStyle(.linear)
                    Text("Verifying the signature and notarization…").font(.callout).foregroundStyle(.secondary)
                case .ready:
                    ProgressView().progressViewStyle(.linear)
                    Text("Getting ready to install…").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack { Spacer(); Button("Cancel") { model.cancelInstall() } }
        }
    }

    private func installing(_ offer: UpdateOffer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Installing Mac Cleaner \(offer.version)", "Mac Cleaner is restarting.")
            ProgressView().progressViewStyle(.linear)
        }
    }

    private func result(symbol: String, tint: Color, title: String, message: String, manual: URL? = nil) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol).font(.largeTitle).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            HStack {
                if let manual, UpdateHostPolicy.isSafeLink(manual) {
                    Button("Download manually") { model.openReleasePage(manual) }
                }
                Spacer()
                Button("OK") { model.close() }.keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The release notes as plain text: headings, bullets and github.com links only (see `ReleaseNotes`).
struct NotesView: View {
    let notes: String

    private var lines: [ReleaseNotesLine] { ReleaseNotes.render(notes) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if lines.isEmpty {
                    Text("No release notes were published for this version.").foregroundStyle(.secondary)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    switch line.kind {
                    case .blank: Color.clear.frame(height: 4)
                    case .heading: text(line).font(.callout.weight(.semibold)).padding(.top, 4)
                    case .bullet:
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            text(line).font(.callout)
                        }
                    case .paragraph: text(line).font(.callout)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .textSelection(.enabled)
        }
        .frame(height: 190)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private func text(_ line: ReleaseNotesLine) -> Text {
        var out = AttributedString()
        for run in line.runs {
            var piece = AttributedString(run.text)
            if let link = run.link { piece.link = link }
            out.append(piece)
        }
        return Text(out)
    }
}
