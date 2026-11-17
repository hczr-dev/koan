import SwiftUI
import AppKit
import Combine

/// The answer's own kind chooses its mark; colors show the value itself.
struct CalcMark: View {
    let answer: Calc.Answer?

    var body: some View {
        if let answer, case .color(let rgb) = answer.kind {
            // The color is the tile: the well's own shape, filled with it.
            CalcSwatch(rgb: rgb, side: Omnibox.tile)
        } else {
            FieldMark(symbol: symbol)
        }
    }

    private var symbol: String {
        switch answer?.kind {
        case .units: return "ruler"
        case .currency: return "banknote"
        case .time: return "clock.circle"
        case .date: return "calendar"
        case .numberBase: return "number"
        default: return "calculator.operations"
        }
    }
}

/// A color answer's value as a swatch, on the icon well's corner, the
/// same as Clipboard History's color tiles (ClipMark).
struct CalcSwatch: View {
    let rgb: UInt32
    let side: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .fill(Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                        green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, opacity: 1))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1)) // design: a swatch's ring, not a card
            .frame(width: side, height: side)
    }
}

// The field's own places and its foot, drawn in the card under the field
// (Omnibox): Clipboard History's list and what the chosen clip is, Emoji's
// grid, and the keys Return and ⌘K do, with ⌘K's list of the rest.

/// What a clip is, down the left of its row, on its tile: a link's site, a
/// color itself, the picture small, a file's own icon, words.
struct ClipMark: View {
    let clip: Clips.Clip?

    var body: some View {
        switch clip?.kind {
        case .link:
            let host = clip.flatMap { URL(string: $0.text)?.host()?.lowercased() }
            Mark(icon: host.flatMap { Favicons.shared.cached($0) }, letter: host.map { String($0.prefix(1)).uppercased() } ?? "",
                 size: Omnibox.tile - 4)
                .frame(width: Omnibox.tile, height: Omnibox.tile)
        case .color:
            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                .fill(Color(nsColor: clip.flatMap { Clips.hex($0.text) } ?? .gray))
                .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1)) // design: a swatch's ring, not a card
                .frame(width: Omnibox.tile, height: Omnibox.tile)
        case .image:
            if let clip, let image = ClipImages.shared.thumb(for: clip) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Omnibox.tile, height: Omnibox.tile)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            } else {
                FieldMark(symbol: "photo")
            }
        case .file:
            if let clip { PlaceFileTile(path: clip.text) }
        default:
            FieldMark(symbol: "doc.text")
        }
    }
}

/// A row's mark as Settings draws its pages': a page of Settings, or a
/// feature with a drawing of its own, drawn with the pen as the sidebar
/// has it (PenTile); a feature without a drawing its glyph in ink on the
/// same paper over its color's swipe; the rest a glyph in the gray well
/// (IconWell). Only a feature in its own right wears a color, so the few
/// that do stand out.
struct FieldMark: View {
    @Environment(\.fieldBareMarks) private var bare
    let symbol: String
    var tint: NSColor? = nil
    /// The page of Settings it is, in that page's own drawing and colors.
    var page: SettingsPage? = nil
    /// Words in the well in place of the symbol: Now's "+5".
    var words: String? = nil

    var body: some View {
        // A drawing fills its paper; among the rows' glyphs, about half a
        // tile across, it is drawn smaller so no row's mark is the big one.
        if let words {
            Text(words)
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: Omnibox.tile, height: Omnibox.tile)
                .background(Well(tint: nil).id("well"))
        } else if let page, PenArt.has(page) {
            PenTileView(page: page, side: Omnibox.tile, art: 0.78).frame(width: Omnibox.tile, height: Omnibox.tile)
        } else if let tint {
            // A feature's mark is a pen tile whether or not it has a drawing
            // of its own: its glyph in ink on the paper, over its swipe.
            PenTileView(symbol: symbol, tint: tint, side: Omnibox.tile, art: 0.78).frame(width: Omnibox.tile, height: Omnibox.tile)
                .id("\(symbol) \(tint)")
        } else {
            // 14 across in the well, 13 on a tile, as the Settings sidebar has them.
            Symbol(symbol, size: (tint == nil ? 14 : 13) / Glyphs.scale)
                .foregroundStyle(tint == nil ? Palette.ink : .white)
                .frame(width: Omnibox.tile, height: Omnibox.tile)
                .background { if !bare { Well(tint: nil).id("well") } }
        }
    }

    private struct Well: NSViewRepresentable {
        let tint: NSColor?
        func makeNSView(context: Context) -> NSView { IconWell() }
        func updateNSView(_ view: NSView, context: Context) {}
    }
}

/// Clipboard History: what was copied, newest first under what is pinned,
/// and beside it all of the chosen one and where it came from.
struct ClipPlace: View {
    let browser: Browser
    @ObservedObject var query: Query
    /// As tall as the window leaves room for (Omnibox.placeRoom).
    var height: CGFloat = Omnibox.placeHeight
    /// The card's ground, which the list fades into at its foot.
    var ground: Color = Palette.ground
    @ObservedObject private var clips = Clips.shared
    @State private var visibleCount = 80

    var body: some View {
        let list = clips.find(query.typed, kind: query.clipFilter)
        let chosen = list.indices.contains(query.spot) ? list[query.spot] : nil
        if list.isEmpty, let empty = browser.clipEmpty {
            PlaceEmptyView(browser: browser, query: query, empty: empty)
                .belowField()
                .frame(height: height)
        } else {
            HStack(spacing: 0) {
                rows(list)
                    .frame(width: 320)
                Rectangle()
                    .fill(Omnibox.seam)
                    .frame(width: 1)
                    .belowField()
                ClipPreview(clip: chosen)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .belowField()
            }
            .frame(height: height)
        }
    }

    private func rows(_ list: [Clips.Clip]) -> some View {
        ScrollViewReader { reader in
            ThreadScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.prefix(max(visibleCount, query.spot + 1)).enumerated()), id: \.element.id) { index, clip in
                        VStack(alignment: .leading, spacing: 0) {
                            if index == 0 || section(list[index - 1]) != section(clip) {
                                Text(section(clip))
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.muted)
                                    .padding(.horizontal, Omnibox.gutter - Omnibox.inset)
                                    .padding(.top, index == 0 ? 4 : 12)
                                    .padding(.bottom, 6)
                            }
                            row(clip, chosen: index == query.spot)
                                .id(clip.id)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { query.spot = index; _ = browser.runPrimary() }
                                .onTapGesture { query.spot = index }
                                .overlay { FieldRowMenu(name: "clip \(index)") { browser.showActions(forSpot: index) } }
                                .onAppear {
                                    if index >= visibleCount - 12 { visibleCount = min(list.count, visibleCount + 80) }
                                }
                        }
                    }
                }
                .padding(Omnibox.inset)
            }
            .edgeScroll()
            .onChange(of: query.typed) { _, _ in visibleCount = 80 }
            .onChange(of: query.clipFilter) { _, _ in visibleCount = 80 }
            .onChange(of: query.spot) { _, spot in
                if list.indices.contains(spot) {
                    visibleCount = max(visibleCount, spot + 1)
                    DispatchQueue.main.async { reader.scrollTo(list[spot].id) }
                }
            }
        }
    }

    private func row(_ clip: Clips.Clip, chosen: Bool) -> some View {
        HStack(spacing: Omnibox.gap) {
            ClipMark(clip: clip)
            Text(clip.title)
                .font(.system(size: 13.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if clip.pinned {
                Symbol("pin.fill", size: 10).foregroundStyle(Palette.muted)
            }
        }
        .padding(.horizontal, Omnibox.gutter - Omnibox.inset)
        .frame(height: Omnibox.rowHeight)
        .background {
            if chosen {
                RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
        .transaction { $0.animation = nil }
    }

    private func section(_ clip: Clips.Clip) -> String {
        if clip.pinned { return "Pinned" }
        let calendar = Calendar.current
        if calendar.isDateInToday(clip.last) { return "Today" }
        if calendar.isDateInYesterday(clip.last) { return "Yesterday" }
        return "Earlier"
    }
}

/// All of one clip, and what is known of it.
struct ClipPreview: View {
    let clip: Clips.Clip?
    @Environment(\.colorScheme) private var look

    var body: some View {
        if let clip {
            let text = clip.kind == .text ? Clips.shared.preview(clip) : nil
            let facts = self.facts(clip, text: text)
            ScrollViewReader { reader in
                ThreadScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        content(clip, text: text)
                            .frame(maxWidth: .infinity)
                            .frame(height: 160)
                            .background(look == .dark ? Palette.ground : Palette.hover)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            // As wide as the lines under it, hairline to hairline.
                            .padding(.horizontal, 8)
                            .id(PlacePreview.top)
                        VStack(spacing: 0) {
                            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                                line(fact.0, fact.1, clip: clip)
                                if index < facts.count - 1 {
                                    Rectangle().fill(Omnibox.seam).frame(height: 0.5).padding(.horizontal, 8)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .edgeScroll()
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: clip.id) { _, _ in reader.scrollTo(PlacePreview.top, anchor: .top) }
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ clip: Clips.Clip, text: ClipText?) -> some View {
        switch clip.kind {
        case .color:
            // As a launcher reads a color: the value as written on the left,
            // the color itself on the right, each named under it.
            HStack(spacing: 0) {
                VStack(spacing: 12) {
                    Text(clip.text.uppercased())
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    colorLabel("HEX")
                }
                .frame(maxWidth: .infinity)
                ZStack {
                    Rectangle().fill(Omnibox.seam).frame(width: 1).padding(.vertical, 16)
                    Symbol("arrow.right", size: 13)
                        .foregroundStyle(Palette.ink)
                        .padding(.vertical, 6)
                        .background(look == .dark ? Palette.ground : Palette.hover)
                }
                .frame(width: 24)
                VStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Color(nsColor: Clips.hex(clip.text) ?? .gray))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(.white, lineWidth: 2.5)) // design: a swatch's ring, not a card
                        .frame(width: 96, height: 64)
                    colorLabel("Color")
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image:
            if let image = ClipImages.shared.image(for: clip) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: 140)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            } else {
                Symbol("photo", size: 24).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .file:
            FilePicture(path: clip.text, side: 280)
                .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: 140)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        case .link:
            VStack(alignment: .leading, spacing: 6) {
                if let title = clip.pageTitle {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                }
                Text(clip.text)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.vertical, 12)
            .padding(.horizontal, 14) // design: approved preview's text inset
        case .text:
            if let text { ClipTextScroll(text: text) }
        }
    }

    /// The small name under each half of a color.
    private func colorLabel(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Omnibox.tileFill))
    }

    private func facts(_ clip: Clips.Clip, text: ClipText?) -> [(String, String)] {
        var out: [(String, String)] = []
        if let app = clip.app { out.append(("Source", app)) }
        if let page = clip.page { out.append(("Page", clip.pageTitle ?? page.host() ?? page.absoluteString)) }
        if clip.kind == .file {
            out.append(("Name", URL(fileURLWithPath: clip.text).lastPathComponent))
            out.append(("Where", clip.folder))
            out.append(("Kind", clip.fileKind))
        } else {
            out.append(("Content type", text?.kind ?? clip.kind.rawValue.capitalized))
            if let lines = text?.lines { out.append(("Lines", lines)) }
            else { out.append(("Size", size(clip, text: text?.text))) }
        }
        out.append(("Last copied", clip.lastCopied()))
        return out
    }

    private func line(_ label: String, _ value: String, clip: Clips.Clip) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if label == "Source", let icon = ClipApps.shared.icon(clip.bundle) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else if label == "Page", let host = clip.page?.host()?.lowercased(), let icon = Favicons.shared.cached(host) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else if label == "Where" {
                    Image(nsImage: ClipApps.shared.folder).resizable().frame(width: 16, height: 16)
                }
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(label == "Page" ? Color.accentColor : Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private func size(_ clip: Clips.Clip, text: String?) -> String {
        switch clip.kind {
        case .image: return clip.text.replacingOccurrences(of: "Image (", with: "").replacingOccurrences(of: ")", with: "")
        case .file, .color: return ByteCountFormatter.string(fromByteCount: Int64(clip.bytes), countStyle: .file)
        default:
            let text = text ?? clip.text
            let words = text.split(whereSeparator: \.isWhitespace).count
            return "\(text.count) characters, \(words) word\(words == 1 ? "" : "s")"
        }
    }
}

/// A drawing rather than an editor: the preview cannot change the kept
/// words, wrap an indent or put an ellipsis over the last visible line.
/// A clip's words in the well, wrapped to its width; a long one scrolls
/// inside the well, so the well keeps its height.
private struct ClipTextScroll: View {
    let text: ClipText

    var body: some View {
        GeometryReader { box in
            let words = text.drawing()
            let tall = ceil(words.boundingRect(with: NSSize(width: max(0, box.size.width - 28), height: .greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 24
            ThreadScrollView(.vertical) {
                ClipTextDrawing(words: words, text: text.text)
                    .frame(width: box.size.width, height: max(tall, box.size.height))
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

private struct ClipTextDrawing: NSViewRepresentable {
    let words: NSAttributedString
    let text: String

    func makeNSView(context: Context) -> Drawing { Drawing() }
    func updateNSView(_ view: Drawing, context: Context) {
        view.words = words
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityValue(text)
        view.needsDisplay = true
    }

    final class Drawing: NSView {
        var words = NSAttributedString(string: "")
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: bounds).addClip()
            words.draw(with: NSRect(x: 14, y: 12, width: max(0, bounds.width - 28), height: max(0, bounds.height - 24)),
                       options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The picture of the clip being looked at, read and opened once, not on
/// every redraw: the one chosen, and the one before it.
@MainActor
final class ClipImages {
    static let shared = ClipImages()
    private var kept: [(UUID, NSImage)] = []

    /// The picture small, for its row's tile: made once a clip, kept.
    private var thumbs: [UUID: NSImage] = [:]

    func thumb(for clip: Clips.Clip) -> NSImage? {
        if let hit = thumbs[clip.id] { return hit }
        guard let image = image(for: clip) else { return nil }
        let side = Omnibox.tile * 2
        let scale = side / max(1, min(image.size.width, image.size.height))
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let small = NSImage(size: size, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
        if thumbs.count > 200 { thumbs.removeAll() }
        thumbs[clip.id] = small
        return small
    }

    func image(for clip: Clips.Clip) -> NSImage? {
        if let hit = kept.first(where: { $0.0 == clip.id }) { return hit.1 }
        guard let image = Clips.shared.image(clip) else { return nil }
        kept.insert((clip.id, image), at: 0)
        if kept.count > 2 { kept.removeLast() }
        return image
    }
}

/// Emoji: a grid of big tiles, as a launcher's picker has it, eight
/// across: Frequently Used first, yours and then the ones most people use,
/// then every part under its heading and how many it holds. With words,
/// what they find. The chosen one is lit and ringed.
struct EmojiPlace: View {
    let browser: Browser
    @ObservedObject var query: Query
    var height: CGFloat = Omnibox.placeHeight
    var ground: Color = Palette.ground

    /// Between tiles, across and down.
    static let gap: CGFloat = 8

    var body: some View {
        let sections = browser.emojiSections
        let words = browser.emojiWords ?? ""
        // No name found them and the meaning is still being made: one slot
        // says more may come, where "No emoji for that" would be wrong.
        let waiting = sections.isEmpty && !words.isEmpty && !Emoji.settled
        let starts = sections.indices.map { index in sections.prefix(index).reduce(0) { $0 + $1.list.count } }
        if let empty = browser.emojiEmpty {
            PlaceEmptyView(browser: browser, query: query, empty: empty)
                .belowField()
                .frame(height: height)
        } else {
            grid(sections, starts: starts, waiting: waiting)
        }
    }

    private func grid(_ sections: [(title: String, list: [Emoji.One])], starts: [Int], waiting: Bool) -> some View {
        ScrollViewReader { reader in
            ThreadScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if waiting {
                        Text("Looking by meaning…")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, Omnibox.gutter - Omnibox.inset)
                            .padding(.top, 4)
                    }
                    // Parts go by their headings: a number would be a
                    // scroll target the tiles' own numbers collide with,
                    // and scrollTo(5) would go to the sixth part.
                    ForEach(Array(sections.enumerated()), id: \.element.title) { part, section in
                        HStack(spacing: 8) {
                            Text(section.title)
                                .foregroundStyle(Palette.muted)
                            Text("\(section.list.count)")
                                .foregroundStyle(Palette.faint)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, Omnibox.gutter - Omnibox.inset)
                        .padding(.top, part == 0 ? 4 : 16)
                        .padding(.bottom, 8)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap), count: Omnibox.emojiColumns), spacing: Self.gap) {
                            ForEach(Array(section.list.enumerated()), id: \.offset) { at, one in
                                let index = starts[part] + at
                                tile(one, chosen: index == query.spot)
                                    .id(index)
                                    .onTapGesture { query.spot = index; _ = browser.runPrimary() }
                            }
                        }
                        if waiting { EmojiWaiting() }
                    }
                }
                .padding(Omnibox.inset)
            }
            .edgeScroll()
            .frame(height: height)
            .onChange(of: query.spot) { _, spot in reader.scrollTo(spot) }
        }
        .transaction { $0.animation = nil }
        // What the emoji mean is made the first time the grid shows; then
        // the words typed find again, by meaning too.
        .onAppear { Emoji.warm { query.objectWillChange.send() } }
    }

    private func tile(_ one: Emoji.One, chosen: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.surface, style: .continuous)
        // A square as wide as its column, the emoji in its middle.
        return shape.fill(chosen ? Omnibox.chosenFill : Omnibox.tileFill)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Text(one.glyph)
                    .font(.system(size: 34)) // design: an emoji drawn as a picture on its tile, not type
            }
            .overlay {
                if chosen {
                    shape.strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5) // design: the chosen tile's ring, as a launcher's grid rings it
                }
            }
            .contentShape(shape)
            .pointerTip(one.name.capitalized)
    }
}

/// The one slot Emoji holds while it looks by meaning, breathing slowly.
struct EmojiWaiting: View {
    @State private var low = false

    var body: some View {
        Circle()
            .fill(Omnibox.chosenFill)
            .frame(width: 24, height: 24)
            .opacity(low ? 0.35 : 1)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { low = true } }
    }
}

/// The card's foot, floating over what it holds: on the
/// left, in a place of the field's own, its name on glass, the way back;
/// then what is chosen, when it needs saying; on the right one glass pill,
/// what Return does, any featured actions, and Actions, with their keys.
/// In the plain field its left has Yab's own menu, a round button, as
/// Raycast's root has its About menu there.
/// What scrolls under it fades out as it nears it (edgeScroll), with no
/// band of its own: a band of material read as a grey smudge on the white
/// box even with nothing under it.
/// ⌘K's list rises out of its corner (FieldActionsPanel).
struct FieldFoot: View {
    let browser: Browser
    @ObservedObject var query: Query
    @ObservedObject private var actionsKey = Keymap.shared.slot(.fieldActions)
    @ObservedObject private var aboutKey = Keymap.shared.slot(.fieldAbout)
    let place: FieldPlace?
    /// A site's or an extension's search: its mark and name at the left,
    /// the way back, as a place's name is.
    var scope: Scope? = nil
    /// The plain field's: the About menu's button at the left (⇧⌘K).
    var menu = false
    /// A private tab's: the foot says so at its left, where a place's
    /// name would be.
    var shy = false
    let detail: String?
    /// Where ↩ puts the file, beside Files: the field's end is its folder.
    var target: PlaceTarget? = nil
    let primary: String?
    /// The keys said beside it: ↩, or ⌫ for the act on rows picked together.
    var primaryKeys = "↩"
    /// What it does can't be taken back, or takes many: its words in red.
    var danger = false
    let featured: [FieldAction]
    let more: Bool

    /// The room it keeps at the foot of what scrolls: the pill and its air.
    static let room: CGFloat = 50
    static let pill: CGFloat = 34

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 8) {
                if menu {
                    Button { browser.showAbout() } label: { Symbol("menu.bars", size: 12) }
                        .buttonStyle(FootButton(strong: false, round: true))
                        .focusable(false)
                        .padding(2)
                        .background { FieldGlass(shape: Circle()) }
                        .fixedSize()
                        .keyTip("About Menu", keys: aboutKey.keys?.text, side: .above)
                        .accessibilityLabel("About Menu")
                        .background(ClickZone(away: query.away))
                        // The menu stands where it is: glass over glass.
                        .opacity(query.choosingAbout && query.acting != nil ? 0 : 1)
                    // Invite a Friend, beside it on the same glass: words,
                    // not a badge (Invites.swift, Settings › Invite Friends).
                    Button {
                        browser.close()
                        Command.invite.run(in: browser)
                    } label: {
                        HStack(spacing: 6) {
                            Symbol("brand.blobplus", size: 13)
                            Text("Invite a Friend")
                        }
                    }
                    .buttonStyle(FootButton(strong: true))
                    .focusable(false)
                    .padding(2)
                    .background { FieldGlass(shape: Capsule()) }
                    .fixedSize()
                    .keyTip("Invite a Friend")
                    .accessibilityLabel("Invite a Friend")
                    .opacity(query.choosingAbout && query.acting != nil ? 0 : 1)
                }
                if let place {
                    // What is chosen is said on the same glass as the
                    // place's name, as a launcher says it: over the rows it
                    // was words on whatever passed under.
                    Button { _ = browser.leavePlace() } label: {
                        HStack(spacing: 6) {
                            Symbol(place.symbol, size: 10)
                            Text(place.title)
                                .fixedSize()
                            if let detail {
                                Text(detail)
                                    .foregroundStyle(Palette.muted)
                                    .lineLimit(1)
                            }
                            if let target { PlaceTargetView(target: target) }
                        }
                    }
                    .buttonStyle(FootButton(strong: true))
                    .focusable(false)
                    .padding(2)
                    .background { FieldGlass(shape: Capsule()) }
                    // Its own width, until the pill at the right leaves
                    // less: then what it says is cut short, and the card
                    // keeps its width (#173, a sentence-long upload box
                    // pushed it past the window).
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .keyTip("Back")
                } else if let scope {
                    Button { _ = browser.leaveScope(restoring: true) } label: {
                        HStack(spacing: 6) {
                            Mark(icon: scope.icon, letter: scope.letter, size: 14)
                            Text(scope.name)
                        }
                    }
                    .buttonStyle(FootButton(strong: true))
                    .focusable(false)
                    .padding(2)
                    .background { FieldGlass(shape: Capsule()) }
                    .fixedSize()
                    .keyTip("Back")
                } else if shy, browser.privateLeavable {
                    // Private, as a site's name is: pressed, the way back.
                    Button { _ = browser.leavePrivate() } label: {
                        HStack(spacing: 6) {
                            Symbol("incognito", size: 10)
                            Text("Private")
                        }
                    }
                    .buttonStyle(FootButton(strong: true))
                    .focusable(false)
                    .padding(2)
                    .background { FieldGlass(shape: Capsule()) }
                    .fixedSize()
                    .keyTip("Back")
                } else if shy {
                    // Over a private page's address: said, not pressed,
                    // nothing to go back to.
                    HStack(spacing: 6) {
                        Symbol("incognito", size: 10)
                        Text("Private")
                    }
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, 12)
                    .frame(height: FieldFoot.pill - 4)
                    .padding(2)
                    .background { FieldGlass(shape: Capsule()) }
                    .fixedSize()
                } else if let detail {
                    Text(detail)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // ⌘K's list stands where the pill is: glass over glass would
                // show the pill's words through the list's.
                if let editor = query.edit?.passwordEditor {
                    PasswordEditFoot(browser: browser, model: editor.model)
                } else if let primary, query.acting == nil || query.choosingModel || query.choosingFilter || query.choosingAbout {
                    HStack(spacing: 0) {
                        Button { _ = browser.runPrimary() } label: { FieldFoot.label(primary, primaryKeys) }
                            .buttonStyle(FootButton(strong: true, danger: danger))
                            .focusable(false)
                        ForEach(featured) { action in
                            Button { _ = browser.runAction(action.id) } label: {
                                FieldFoot.label(action.title, action.shownKeys)
                            }
                                .buttonStyle(FootButton(strong: false))
                                .focusable(false)
                        }
                        if query.edit != nil {
                            // Writing a row: the other way out of it.
                            Button { browser.cancelEdit() } label: { FieldFoot.label("Cancel", "esc") }
                                .buttonStyle(FootButton(strong: true))
                                .focusable(false)
                        } else if more {
                            // Available but quieter than what Return does.
                            Button { browser.showActions() } label: { FieldFoot.label("Actions", actionsKey.keys?.text ?? "") }
                                .buttonStyle(FootButton(strong: false))
                                .focusable(false)
                                .keyTip("Actions")
                        }
                    }
                    .padding(2)
                    .background { FieldGlass(shape: Capsule()) }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if query.answering, query.footPill != width { query.footPill = width }
                    }
                }
            }
            .frame(height: Self.pill)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        // The band reaches a little above the room; the pill keeps to it,
        // from the bottom.
        .frame(height: Self.room, alignment: .bottom)
        .transaction { $0.animation = nil }
        .overlay(alignment: .bottomTrailing) {
            if query.acting != nil, !query.choosingModel, !query.choosingFilter, !query.choosingAbout {
                // Over the pill, as a launcher's list covers its own.
                FieldActionsPanel(browser: browser, query: query)
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    // Its native search editor stays at its final backing
                    // scale throughout the fade, like the main field.
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if query.acting != nil, query.choosingAbout {
                // Over its button, the pill left standing on the right.
                FieldActionsPanel(browser: browser, query: query)
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            }
        }
        .animation(query.acting == nil ? Motion.depart : Motion.arrive, value: query.acting != nil)
    }

    /// A button's words and the keys that press it, as every button in
    /// the app has them: the keys at the words' size, at 0.6, 6 apart.
    static func label(_ words: String, _ keys: String) -> some View {
        HStack(spacing: 6) {
            Text(words)
            KeyGlyphs(keys: keys, size: 13.5, tint: nil, rest: 0.6)
                .transaction { $0.animation = nil }
        }
    }
}

/// Liquid Glass where the Mac has it, as the extensions' and the downloads'
/// popovers are: the rows behind it show through, bent and blurred, and
/// its rim is the glass's own. Before, or where transparency is turned
/// down, the row's wash under a material and a hairline, so it still
/// stands off the box's ground. Lifted, it also has a card's shadow, for
/// what floats over the rows (⌘K's list).
struct FieldGlass<S: InsettableShape>: View {
    let shape: S
    var lifted = false
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        Group {
            if #available(macOS 26.0, *), !solid {
                // What floats over the rows (⌘K's list) has a material under
                // its glass, as the box has: glass alone let the rows and
                // the page read through its own words.
                ZStack {
                    if lifted { shape.fill(.regularMaterial) }
                    Color.clear.glassEffect(.regular, in: shape)
                }
            } else {
                ZStack {
                    shape.fill(Palette.wash.opacity(lifted ? 1 : 0.8))
                    if !solid { shape.fill(.ultraThinMaterial) }
                }
                .overlay(shape.strokeBorder(Palette.hairline, lineWidth: 1)) // design: glass, not a card: the wash and a card's hairline under it
            }
        }
        .shadow(color: .black.opacity(lifted ? 0.14 : 0), radius: 24, y: 8) // design: the card's own shadow (floatingFrame), for the list that floats
    }
}

/// Observes the draft directly so Save follows validation and owner-proof state.
private struct PasswordEditFoot: View {
    let browser: Browser
    @ObservedObject var model: PasswordEditModel

    var body: some View {
        HStack(spacing: 0) {
            Button { browser.cancelEdit() } label: { FieldFoot.label("Cancel", "esc") }
                .buttonStyle(FootButton(strong: false))
                .focusable(false)
            Button { browser.saveEdit() } label: { FieldFoot.label("Save", "⏎") }
                .buttonStyle(FootButton(strong: true))
                .focusable(false)
                .disabled(!model.canSave)
        }
        .padding(2)
        .background { FieldGlass(shape: Capsule()) }
        .fixedSize()
    }
}

/// One part of the foot's glass: its own capsule under the pointer,
/// pressed on the app's press (Press), the words in ink or, while it is
/// not what Return does, muted.
/// The foot pill's buttons, the field's and mail's (MailFootPill).
struct FootButton: ButtonStyle {
    let strong: Bool
    /// A mark alone, on a circle as tall as the words' capsules.
    var round = false
    /// The act on rows picked together: its words in the red of what
    /// cannot be undone (ButtonCSS.danger).
    var danger = false

    /// A key's plate in the foot: the capsule less 5 above and below.
    static let plate: CGFloat = FieldFoot.pill - 4 - 2 * 5
    /// From the last plate to the capsule's round end.
    static let end: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration, strong: strong, round: round, danger: danger)
    }

    private struct Face: View {
        let configuration: Configuration
        let strong: Bool
        let round: Bool
        let danger: Bool
        @State private var hovering = false
        @Environment(\.accessibilityReduceMotion) private var still

        var body: some View {
            let pressed = configuration.isPressed
            Group {
                if round {
                    configuration.label
                        .frame(width: FieldFoot.pill - 4, height: FieldFoot.pill - 4)
                } else {
                    configuration.label
                        // Its keys' plates sit inside its capsule as a
                        // launcher's do: 5 above and below, 7 from its round
                        // end so a plate's corners stay inside the curve, 8
                        // from the words, which stand 12 in.
                        .environment(\.keyPlate, KeyPlate(height: FootButton.plate, pull: 12 - FootButton.end, lead: 2))
                        .padding(.trailing, 12)
                        .modifier(LeadingRoom(padding: 14))
                        .frame(height: FieldFoot.pill - 4)
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(danger ? ButtonCSS.danger : strong || hovering ? Palette.ink : Palette.ink.opacity(0.72))
            .background(Capsule().fill(Palette.ink.opacity(pressed ? 0.1 : hovering ? 0.06 : 0)))
            .contentShape(Capsule())
            .scaleEffect(pressed && !still ? ButtonSize.small.pressed : 1)
            .animation(pressed ? Press.down : Press.up, value: pressed)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

extension View {
    /// What the card holds, with the foot floating over its bottom and room
    /// kept under its last row to clear it.
    func footed(_ foot: some View, shown: Bool = true) -> some View {
        ZStack(alignment: .bottom) {
            self
            if shown { foot }
        }
    }

    /// A list the field and the foot float over: room kept above its first
    /// row and under its last to clear them. Under the field a row goes on
    /// at full strength, blurred by the field's band (Omnibox); under the
    /// foot it fades out, one mask of the scroll view's, drawn by the
    /// window server, and nothing at all where no row reaches the foot.
    func edgeScroll(bottomInset: CGFloat = 0) -> some View {
        modifier(EdgeScroll(bottomInset: bottomInset))
    }

    /// What sits beside a list rather than scrolling under the field (a
    /// place's preview, its hairline, an empty place's words): below it.
    func belowField() -> some View {
        modifier(BelowField())
    }
}

extension EnvironmentValues {
    /// How much of the top of the box's content the field stands over.
    @Entry var underField: CGFloat = 0
    /// Marks drawn bare, with no well under them: the compact card's
    /// rows, as the example it was drawn from has its glyphs.
    @Entry var fieldBareMarks = false
    /// Whether the foot floats over the bottom of the box's list: not
    /// under the compact field's rows, which end where the card does.
    @Entry var fieldFooted = true
}

private struct EdgeScroll: ViewModifier {
    let bottomInset: CGFloat
    @Environment(\.underField) private var top
    @Environment(\.fieldFooted) private var footed

    func body(content: Content) -> some View {
        content
            .contentMargins(.top, top, for: .scrollContent)
            .contentMargins(.top, top, for: .scrollIndicators)
            .contentMargins(.bottom, footed ? FieldFoot.room + 8 : 0, for: .scrollContent)
            // The column's thread, not macOS's scroller.
            .background(ColumnThread())
            // Keep the compact card's gap outside the scrolling viewport,
            // while the thread still measures the scroll view itself and
            // the fade spans the whole card.
            .padding(.bottom, bottomInset)
            // A soft edge, as macOS 26's under a bar: a row runs on under
            // the foot's pills to the box's edge, fading and blurring as it
            // goes, so the glass has something to bend and the words never
            // compete with the pills'.
            .mask {
                VStack(spacing: 0) {
                    // Rows scrolled up under the field fade out before
                    // they reach its words, so what is typed never sits on
                    // a row's own (#848).
                    if top > 0 {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 0.55),
                                               .init(color: .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: top)
                    }
                    Color.black
                    if footed {
                        LinearGradient(colors: [.black, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                            .frame(height: FieldFoot.room + 14) // design: from a little over the pills' tops to the box's foot
                    } else {
                        // No foot: a row scrolled past the card's foot fades
                        // out at its edge instead of being cut there.
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 10)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if footed {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                        .frame(height: FieldFoot.room + 14)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct BelowField: ViewModifier {
    @Environment(\.underField) private var top

    func body(content: Content) -> some View {
        content
            .padding(.top, top)
            .environment(\.underField, 0)
    }
}

/// ⌘K's list, in the box, rising out of its corner over the foot's pill as
/// a launcher's does, on glass: at its head what it acts on, then a row an
/// action, its mark, its words and its keys, a line at a destructive
/// boundary, and at its foot a search of its own, which has the keyboard
/// while it is up: typing narrows the list, the arrows walk it, Return
/// does what is chosen, Escape and ⌘K put it away.
struct FieldActionsPanel: View {
    let browser: Browser
    @ObservedObject var query: Query
    @ObservedObject private var hotkeys = Hotkeys.shared
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 350
    /// Its corners: the box's less the 8 it stands in from them, so in a
    /// corner of the box it runs on the box's curve, and its chosen row's
    /// 10, 8 in from its own edge, on its.
    static let corner: CGFloat = Radius.box - 8
    /// Where it grows from and goes back to: the Actions button, the end of
    /// the pill it stands over.
    static let growth = UnitPoint(x: 0.84, y: 0.96)
    static let row: CGFloat = 36

    private enum Boundary: Equatable { case line, space }

    var body: some View {
        let _ = hotkeys.version
        let actions = browser.shownActions
        VStack(alignment: .leading, spacing: 0) {
            Text(subject)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            // A scroll view only for a list longer than the panel: most are
            // seven or fewer, and a scroll view is an NSScrollView to make,
            // the panel's first frame late by it.
            if height(actions) < fullHeight(actions) {
                ScrollViewReader { reader in
                    ThreadScrollView(.vertical) { rows(actions) }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: height(actions))
                        .onChange(of: query.acting) { _, acting in
                            if let acting, actions.indices.contains(acting) { reader.scrollTo(actions[acting].id) }
                        }
                }
            } else {
                rows(actions)
            }
            Rectangle()
                .fill(Omnibox.seam)
                .frame(height: 1)
                .padding(.top, 4)
            // As tall as a launcher's, its words as large as the rows'.
            ActionSearch(browser: browser, query: query)
                .frame(height: 20)
                .padding(.horizontal, 16)
                .frame(height: 48)
        }
        .frame(width: Self.width)
        .background { FieldGlass(shape: RoundedRectangle(cornerRadius: Self.corner, style: .continuous), lifted: true) }
        .background(ClickZone(away: query.away))
        .transaction { $0.animation = nil }
    }

    private func row(_ action: FieldAction, index: Int) -> some View {
        HStack(spacing: 12) {
            // What it goes to, drawn as that is (ActionIcons); else the
            // app's own mark, in ink as the words are: muted, the marks
            // read as faded beside them.
            Group {
                if let image = action.image {
                    Image(nsImage: image).resizable().interpolation(.high).frame(width: 16, height: 16)
                        // A dark icon on a dark box, on a light plate.
                        .padding(scheme == .dark && ActionIcons.inky(image) ? 1.5 : 0)
                        .background {
                            if scheme == .dark, ActionIcons.inky(image) {
                                RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(Color.white.opacity(0.9))
                            }
                        }
                        .frame(width: 16, height: 16)
                } else {
                    Symbol(action.symbol, size: 12).foregroundStyle(action.danger ? ButtonCSS.danger : Palette.ink)
                }
            }
            .frame(width: 16)
            // What goes for good in the red of what can't be undone, as a
            // menu's destructive item: Delete from History.
            Text(action.title)
                .font(.system(size: 13.5))
                .foregroundStyle(action.danger ? ButtonCSS.danger : Palette.ink)
                .lineLimit(1)
            Spacer(minLength: 16)
            // Choosing what the list is narrowed to, ↩ takes the row walked
            // to, and the one chosen now is ticked.
            let keys = index == 0 && !query.choosingFilter && !query.choosingAbout ? "↩" : action.shownKeys
            if action.checked {
                Symbol("checkmark", size: 11, weight: .semibold).foregroundStyle(Palette.ink)
            } else if !keys.isEmpty {
                KeyGlyphs(keys: keys, size: 13.5)
            } else if !action.note.isEmpty {
                Text(action.note)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.row)
        .background {
            // Ink, not the rows' wash: on glass, over rows washed the same,
            // the wash would not show which is chosen.
            if index == query.acting {
                RoundedRectangle(cornerRadius: Radius.surface, style: .continuous).fill(Omnibox.chosenFill)
            }
        }
        .contentShape(Rectangle())
        // Only while it is up: a panel going away under a resting pointer
        // never brings itself back.
        .onHover { if $0, query.acting != nil { query.acting = index } }
        .onTapGesture {
            query.acting = index
            browser.submit()
        }
    }

    /// As tall as its rows, up to seven and a half, so a longer list shows
    /// that it goes on.
    private func height(_ actions: [FieldAction]) -> CGFloat {
        min(fullHeight(actions), Self.row * 7.5)
    }

    private func fullHeight(_ actions: [FieldAction]) -> CGFloat {
        var extra: CGFloat = 0
        for index in actions.indices where index > 0 {
            switch boundary(in: actions, before: index) {
            case .line: extra += 9
            case .space: extra += 4
            case nil: break
            }
        }
        return CGFloat(max(1, actions.count)) * Self.row + extra
    }

    private func rows(_ actions: [FieldAction]) -> some View {
        VStack(spacing: 0) {
            if actions.isEmpty {
                Text("No actions")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: Self.row)
            }
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if boundary(in: actions, before: index) == .line {
                    Rectangle()
                        .fill(Omnibox.seam)
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                } else if boundary(in: actions, before: index) == .space {
                    Color.clear.frame(height: 4)
                }
                row(action, index: index)
                    .id(action.id)
            }
        }
        .padding(.horizontal, 8)
    }

    /// What the list acts on: the chosen row, clip or emoji, by name.
    private var subject: String {
        if query.choosingFilter { return query.place == .files || query.place == .bookmarks ? "Look In" : "Show" }
        if browser.emojiWords != nil {
            let list = browser.placeEmoji
            return list.indices.contains(query.spot) ? list[query.spot].name.capitalized : ""
        }
        if query.place == .clipboard {
            let list = browser.placeClips
            return list.indices.contains(query.spot) ? list[query.spot].title : ""
        }
        if query.choosingModel { return "Answer Again On" }
        if query.choosingAbout { return Updater.version.first?.isNumber == true ? "Yab v\(Updater.version)" : "Yab" }
        if query.answering { return "Answer" }
        if let place = query.place { return browser.placeItem?.title ?? place.title }
        guard let index = query.current, query.offers.indices.contains(index) else { return "" }
        return query.offers[index].key
    }

    /// Long lists use a little space between parts. One line introduces a
    /// destructive run, or follows it when that run starts the list.
    private func boundary(in actions: [FieldAction], before index: Int) -> Boundary? {
        guard index > 0 else { return nil }
        if destructive(actions[index]), !destructive(actions[index - 1]) { return .line }
        if !destructive(actions[index]), destructive(actions[index - 1]),
           actions[..<index].allSatisfy(destructive) { return .line }
        if actions.count > 4, part(actions[index]) != part(actions[index - 1]) { return .space }
        return nil
    }

    private func destructive(_ action: FieldAction) -> Bool {
        switch action.id {
        case "closetab", "delete", "clear", "forget", "forgetsite", "never", "dismiss", "answers", "dropcode", "trash":
            return true
        default:
            return action.id.hasPrefix("recent")
        }
    }

    /// Which part of the list an action is in.
    private func part(_ action: FieldAction) -> Int {
        let parts: [String: Int] = ["copy": 1, "plain": 1, "behind": 1, "ahead": 1, "copylink": 1, "closetab": 2,
                                    "page": 1, "link": 1, "pin": 2, "delete": 3, "clear": 3, "forget": 2,
                                    "later": 1, "tomorrow": 1, "done": 2, "never": 2, "dismiss": 1]
        return max(action.group, parts[action.id] ?? 0)
    }
}

/// ⌘K's own search, at the foot of its list: a bare line of text, which
/// takes the keyboard as the list comes up and gives it back to the field
/// as the list goes (Query.acting).
private struct ActionSearch: NSViewRepresentable {
    let browser: Browser
    @ObservedObject var query: Query

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, query: query) }

    func makeNSView(context: Context) -> NSTextField {
        // Give AppKit search-field behavior rather than a generic text
        // editor. The panel supplies its own layout and action controls.
        let field = NSSearchField()
        field.isAutomaticTextCompletionEnabled = false
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13.5)
        field.textColor = NSColor(Palette.ink)
        field.placeholderString = "Search actions…"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != query.actionWords { field.stringValue = query.actionWords }
        let hint = query.choosingModel ? "Search models…" : query.choosingFilter ? filterHint : "Search actions…"
        if field.placeholderString != hint { field.placeholderString = hint }
    }

    private var filterHint: String {
        switch query.place {
        case .files?, .bookmarks?: return "Search folders…"
        case .clipboard?: return "Search types…"
        default: return query.stock.sites.isEmpty ? "Search filters…" : "Search filters and sites…"
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let browser: Browser
        let query: Query

        init(browser: Browser, query: Query) {
            self.browser = browser
            self.query = query
        }

        @MainActor
        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            query.actionWords = field.stringValue
            query.acting = 0
        }

        @MainActor
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): browser.walk(-1)
            case #selector(NSResponder.moveDown(_:)): browser.walk(1)
            case #selector(NSResponder.insertNewline(_:)): browser.submit()
            case #selector(NSResponder.cancelOperation(_:)): query.acting = nil
            default: return false
            }
            return true
        }
    }
}

/// What needs you, down the left of its row: the picture of its kind with
/// its site's mark, as the new tab's rows had them.
struct HintMark: View {
    let hint: Hint?

    var body: some View {
        Group {
            switch hint?.icon {
            case .face:
                FieldMark(symbol: "agent.face")
            case .symbol(let name):
                FieldMark(symbol: name)
            case .picture(let kind, let site):
                HintPicture(kind: kind, site: site, size: Omnibox.tile)
                    .saturation(hint?.seen == nil ? 1 : 0.25)
            case .site(let host):
                let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
                Mark(icon: Favicons.shared.cached(host) ?? Favicons.shared.cached(bare),
                     letter: bare.first.map { String($0).uppercased() } ?? "",
                     size: Omnibox.tile - 4)
            case nil:
                Color.clear
            }
        }
        .frame(width: Omnibox.slot, height: Omnibox.slot)
    }
}
