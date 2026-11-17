import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Smart Downloads in the column beside the page, where web panels open:
/// a field for magnets and links, a torrent file's door, and every job with
/// its progress, speed and peers or connections.
struct SmartDownloadsColumn: View {
    let browser: Browser
    let width: CGFloat
    @ObservedObject private var smart = SmartDownloads.shared
    @State private var draft = ""
    @Environment(\.tabTitleSize) private var titleSize
    private static let inset: CGFloat = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                Symbol("arrow.down.circle", size: 14)
                    .foregroundStyle(Palette.muted)
                    .frame(width: SideBar.mark, height: SideBar.mark)
                    .padding(.trailing, SideBar.markGap - 2) // design: the column's gap from mark to title
                Text("Smart Downloads")
                    .font(.system(size: titleSize, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if Debrid.service != .none {
                    Text(Debrid.service.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .padding(.trailing, 4) // design: air before the doors
                }
                Door(icon: "doc.badge.plus", help: "Open Torrent File…") { pickTorrents() }
                if smart.jobs.contains(where: \.finished) {
                    Door(icon: "trash", help: "Clear Finished") { smart.clearFinished() }
                }
                Door(icon: "xmark", help: "Close") { smart.close(in: browser) }
            }
            .padding(.leading, (SideBar.row - SideBar.mark) / 2) // design: the mark's middle half a row in
            .padding(.trailing, 2) // design: the last door's plate a hair in from the card's edge
            .frame(height: SideBar.row)
            .padding([.horizontal, .top], Self.inset)
            TextField("Paste a magnet, torrent or download link", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    smart.add(text: draft)
                    draft = ""
                }
                .padding(.horizontal, 10) // design: the field in from the card's edge
                .padding(.vertical, 6) // design: its air above and below
            if smart.engineMissing {
                Text("Smart Downloads uses aria2. Install it with Homebrew: brew install aria2")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12) // design: in line with the field
            }
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(smart.jobs) { job in
                        SmartJobRow(job: job)
                    }
                    if smart.jobs.isEmpty {
                        Text("Magnet links, torrent files and links sent here download over many connections at once.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.center)
                            .padding(24) // design: the empty list's air
                    }
                }
                .padding(8) // design: the rows in from the card's edge
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.surface, style: .continuous))
        .background { HUD.plate(Radius.surface, surface: .page) }
        .overlay(alignment: browser.chatLeads ? .trailing : .leading) {
            ChatEdge(browser: browser)
                .offset(x: browser.chatLeads ? Backdrop.inset : -Backdrop.inset)
        }
    }

    private func pickTorrents() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { smart.add(torrentFile: url) }
    }
}

private struct SmartJobRow: View {
    let job: SmartDownloads.Job
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Symbol(icon, size: 11)
                    .foregroundStyle(Palette.muted)
                Text(job.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if job.status == .active || job.status == .waiting {
                    control("pause.fill", "Pause") { SmartDownloads.shared.pause(job) }
                }
                if job.status == .paused {
                    control("play.fill", "Resume") { SmartDownloads.shared.resume(job) }
                }
                if job.status == .complete, job.path != nil {
                    control("magnifyingglass", "Show in Finder") { SmartDownloads.shared.reveal(job) }
                }
                control("xmark", job.finished ? "Remove from List" : "Cancel") { SmartDownloads.shared.remove(job) }
            }
            if job.status != .error && job.status != .removed {
                ProgressView(value: job.status == .complete ? 1 : (job.fraction ?? 0))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(job.status == .error ? ButtonCSS.danger : Palette.muted)
                .lineLimit(2)
        }
        .padding(10) // design: a row's own air
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous) // design: a row's corner in the column
                .fill(Palette.ink.opacity(hovering ? 0.06 : 0.035))
        )
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show in Finder") { SmartDownloads.shared.reveal(job) }
                .disabled(job.path == nil)
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(job.name, forType: .string)
            }
            Divider()
            Button(job.finished ? "Remove from List" : "Cancel Download") { SmartDownloads.shared.remove(job) }
        }
    }

    private func control(_ symbol: String, _ label: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Symbol(symbol, size: 10)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.muted)
        .keyTip(label)
        .accessibilityLabel(label)
    }

    private var icon: String {
        switch job.kind {
        case .torrent: "arrow.triangle.branch"
        case .debrid: "bolt.fill"
        case .link: "arrow.down"
        }
    }

    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    private var detail: String {
        switch job.status {
        case .resolving: return job.note
        case .error: return job.note.isEmpty ? "Failed" : job.note
        case .complete: return "Done · " + size(job.total)
        case .paused: return "Paused · " + size(job.done) + (job.total > 0 ? " of " + size(job.total) : "")
        case .waiting: return "Waiting…"
        case .removed: return "Canceled"
        case .active:
            var parts = [size(job.done) + (job.total > 0 ? " of " + size(job.total) : ""), size(job.speed) + "/s"]
            parts.append(job.kind == .torrent ? "\(job.connections) peers" + (job.seeders > 0 ? ", \(job.seeders) seeding" : "")
                                              : "\(job.connections) connections")
            return parts.joined(separator: " · ")
        }
    }
}

/// The list's door in the panels' row, while there is anything in it.
struct SmartDownloadsButton: View {
    @ObservedObject var browser: Browser
    @ObservedObject private var smart = SmartDownloads.shared
    @State private var hovering = false
    @Environment(\.tone) private var tone

    var body: some View {
        let on = smart.shown(in: browser)
        let going = smart.jobs.contains { !$0.finished }
        Button { smart.toggle(in: browser) } label: {
            Symbol(going ? "arrow.down.circle.fill" : "arrow.down.circle", size: 14)
                .foregroundStyle(on || hovering ? Palette.ink : Palette.muted(on: tone))
                .frame(width: Door.side + 4, height: Door.side + 4)
                .contentShape(RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous))
        }
        .buttonStyle(Door.Give())
        .focusable(false)
        .background(
            RoundedRectangle(cornerRadius: SideBar.radius, style: .continuous)
                .fill(on ? Palette.wash(on: tone) : (hovering ? Palette.hover(on: tone) : .clear))
        )
        .onHover { hovering = $0 }
        .keyTip("Smart Downloads")
        .accessibilityLabel("Smart Downloads")
    }
}

/// Settings › General: which debrid service unlocks magnets and file hosts'
/// links, and its key.
struct SmartDownloadSettings: View {
    @State private var service = Debrid.service
    @State private var key = Debrid.keyFor(Debrid.service) ?? ""

    var body: some View {
        SettingsRow("Debrid service") {
            DropMenu("Debrid service", options: DebridService.allCases.map { (title: $0.title, value: $0) },
                     selection: Binding(get: { service }, set: { picked in
                         service = picked
                         Debrid.service = picked
                         key = Debrid.keyFor(picked) ?? ""
                     }))
                .fixedSize()
        }
        .settingsAnchor("debrid")
        if service != .none {
            SettingsRow("API key") {
                SecureField("API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onChange(of: key) { _, typed in Debrid.setKey(typed, for: service) }
            }
            .settingsAnchor("debrid-key")
        }
    }
}
