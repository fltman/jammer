import AppKit
import JammerAgent
import SwiftUI

/// Before a model is fetched in the window, the first time and every time: what it is, its size, its publisher,
/// where it comes from and its license, from the install register (`Requirements`; SIBLINGS, "Det som kan behöva
/// installeras"). Nothing is fetched until the user clicks Download.
struct ModelDownloadSheet: View {
    let requirement: Requirement
    let download: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("modelDownload.title", requirement.name)).font(.headline)
            Text(L10n.text("modelDownload.text")).fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                if let b = requirement.sizeBytes { row(L10n.text("modelDownload.size"), ByteCountFormatter.string(fromByteCount: b, countStyle: .file)) }
                row(L10n.text("modelDownload.publisher"), requirement.source.publisher)
                GridRow {
                    Text(L10n.text("modelDownload.source")).foregroundStyle(.secondary)
                    link(requirement.source.url)
                }
                if let v = requirement.source.version { row(L10n.text("modelDownload.version"), v) }
                if let l = requirement.license {
                    GridRow {
                        Text(L10n.text("modelDownload.license")).foregroundStyle(.secondary)
                        link(l.url, title: l.spdx)
                    }
                }
                row(L10n.text("modelDownload.where"), requirement.location)
            }
            HStack {
                Spacer()
                Button(L10n.text("button.cancel")) { cancel() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("settings.models.download")) { download() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("modelDownload.download")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func link(_ url: String, title: String? = nil) -> some View {
        if let u = URL(string: url), u.scheme == "https" {
            Link(title ?? url, destination: u).lineLimit(1).truncationMode(.middle)
        } else {
            Text(title ?? url)
        }
    }

    /// Shows the sheet on `window` (or as a window of its own) and runs `download` only on the user's click.
    @MainActor
    static func ask(_ id: String, on window: NSWindow?, download: @escaping () -> Void) {
        // A model the register doesn't list is never fetched: no sheet, no download (a row with a new id must be
        // added to Requirements first).
        guard let r = Requirements.all.first(where: { $0.id == id }) else {
            NSLog("Jammer: %@ isn't in the install register; not downloaded", id)
            return
        }
        let host = NSHostingController(rootView: AnyView(EmptyView()))
        let close: () -> Void = { [weak host] in
            guard let sheet = host?.view.window else { return }
            if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.close() }
        }
        host.rootView = AnyView(ModelDownloadSheet(requirement: r, download: { close(); download() }, cancel: close))
        let sheet = NSWindow(contentViewController: host)
        sheet.title = r.name
        if let window { window.beginSheet(sheet) } else { sheet.center(); sheet.makeKeyAndOrderFront(nil) }
    }

    /// Settings › Models' row ids, as the register names them.
    static func requirementID(forRow row: String) -> String {
        switch row {
        case "kb-whisper-small-q5": "kb-whisper-small"
        case "kb-whisper-medium-q5": "kb-whisper-medium"
        case "parakeet": "parakeet-tdt-0.6b-v3"
        case "stems": "spleeter-4stems"
        case "soundtrack": "mrx"
        default: row
        }
    }
}
