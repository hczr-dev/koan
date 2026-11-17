import AppKit
import WebKit

/// A passage you highlighted on a page: its words, and a little of what
/// comes before and after them, to find them again when the page loads.
struct Highlight: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var prefix: String
    var suffix: String
    var created: Date
}

struct HighlightedPage: Codable {
    var url: URL
    var title: String
    var items: [Highlight]
}

/// Highlights: select words on a page and press ⇧⌘L, or Highlight in its
/// menu, and they are marked, kept in highlights.json under the page's
/// address, and marked again each time the page loads. The same on words
/// already marked takes the mark away. Everything runs in Yab's own script
/// world: the page can't see it or its list.
@MainActor
final class Highlights {
    static let shared = Highlights()
    private(set) var pages: [String: HighlightedPage] = [:]
    private let file: URL?

    private init(file: URL? = Store.unitTests ? nil : Store.file("highlights.json")) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([String: HighlightedPage].self, from: data) {
            pages = saved
        }
    }

    var any: Bool { pages.values.contains { !$0.items.isEmpty } }

    func count(for url: URL?) -> Int {
        guard let url else { return 0 }
        return pages[Self.key(url)]?.items.count ?? 0
    }

    /// The page's address without its fragment: one page, whatever part of it is in view.
    static func key(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }

    private func save() {
        guard let file, let data = try? JSONEncoder().encode(pages) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// The selection marked, or, inside a mark, that mark taken away.
    func highlight(in web: PageView) {
        guard let url = web.url else { return }
        Task { @MainActor in
            guard let result = try? await web.call(Self.script + "\nreturn window.__yabHL.wrap();", in: .yab) as? [String: Any] else { return }
            let key = Self.key(url)
            if let added = result["added"] as? [String: Any], let id = added["id"] as? String {
                var page = pages[key] ?? HighlightedPage(url: url, title: web.title ?? "", items: [])
                if let title = web.title, !title.isEmpty { page.title = title }
                page.items.append(Highlight(id: id, text: added["text"] as? String ?? "", prefix: added["prefix"] as? String ?? "",
                                            suffix: added["suffix"] as? String ?? "", created: Date()))
                pages[key] = page
                save()
            } else if let removed = result["removed"] as? String {
                pages[key]?.items.removeAll { $0.id == removed }
                if pages[key]?.items.isEmpty == true { pages[key] = nil }
                save()
            }
        }
    }

    /// The page's highlights marked again once it has loaded, and once more
    /// a moment later for what it drew after.
    func restore(in web: PageView) {
        guard let url = web.url, let page = pages[Self.key(url)], !page.items.isEmpty else { return }
        let items = page.items.map { ["id": $0.id, "text": $0.text, "prefix": $0.prefix, "suffix": $0.suffix] }
        Task { @MainActor in
            for wait in [0.0, 1.5] {
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                _ = try? await web.call(Self.script + "\nreturn window.__yabHL.restore(items);", arguments: ["items": items], in: .yab)
            }
        }
    }

    func clear(in web: PageView) {
        guard let url = web.url else { return }
        pages[Self.key(url)] = nil
        save()
        Task { @MainActor in _ = try? await web.call(Self.script + "\nreturn window.__yabHL.clear();", in: .yab) }
    }

    /// Every highlight, page by page, newest first, in a tab of its own.
    func showAll(in browser: Browser) {
        let sorted = pages.values.filter { !$0.items.isEmpty }
            .sorted { ($0.items.map(\.created).max() ?? .distantPast) > ($1.items.map(\.created).max() ?? .distantPast) }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var body = ""
        for page in sorted {
            body += "<section><h2><a href=\"\(esc(page.url.absoluteString))\">\(esc(page.title.isEmpty ? page.url.host() ?? page.url.absoluteString : page.title))</a></h2>"
            body += "<p class=host>\(esc(page.url.host() ?? ""))</p>"
            for item in page.items.sorted(by: { $0.created < $1.created }) {
                body += "<blockquote><mark>\(esc(item.text))</mark></blockquote>"
            }
            body += "</section>"
        }
        if body.isEmpty { body = "<p class=empty>Nothing highlighted yet. Select words on a page and press ⇧⌘L.</p>" }
        let html = """
        <!doctype html><meta charset=utf-8><title>Highlights</title>
        <style>
        :root { color-scheme: light dark; font: 15px/1.5 -apple-system, system-ui; }
        body { max-width: 720px; margin: 48px auto; padding: 0 24px; }
        h1 { font-size: 28px; margin: 0 0 24px; }
        h2 { font-size: 17px; margin: 32px 0 0; } h2 a { color: inherit; text-decoration: none; } h2 a:hover { text-decoration: underline; }
        .host { color: GrayText; margin: 2px 0 10px; font-size: 13px; }
        blockquote { margin: 8px 0; padding: 0; }
        mark { background: rgba(255, 212, 0, .42); color: inherit; border-radius: 3px; padding: 1px 2px; box-decoration-break: clone; -webkit-box-decoration-break: clone; }
        .empty { color: GrayText; }
        </style>
        <h1>Highlights</h1>\(body)
        """
        let encoded = html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard let url = URL(string: "data:text/html;charset=utf-8," + encoded) else { return }
        _ = browser.open(url, foreground: true, atEnd: true)
    }

    /// Defines window.__yabHL in Yab's world, once a page.
    static let script = #"""
    if (!window.__yabHL) {
      const STYLE = 'background-color: rgba(255, 212, 0, 0.42); color: inherit; border-radius: 2px; -webkit-box-decoration-break: clone; box-decoration-break: clone;';
      const textNodes = () => {
        const out = [];
        if (!document.body) return out;
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: n => (n.parentElement && !n.parentElement.closest('script,style,noscript,textarea,input')) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT
        });
        let n;
        while ((n = walker.nextNode())) out.push(n);
        return out;
      };
      const flat = () => {
        const spans = [];
        let text = '';
        for (const n of textNodes()) { spans.push([text.length, n]); text += n.data; }
        return { text, spans };
      };
      const rangeAt = (spans, from, to) => {
        let s = null, e = null;
        for (const [at, n] of spans) {
          const len = n.data.length;
          if (!s && from < at + len) s = [n, from - at];
          if (to <= at + len) { e = [n, to - at]; break; }
        }
        if (!s || !e) return null;
        const r = document.createRange();
        r.setStart(s[0], s[1]);
        r.setEnd(e[0], e[1]);
        return r;
      };
      // The words a range covers, as the page shows them: no style or script.
      const textOf = (range) => textNodes().filter(n => range.intersectsNode(n)).map(n =>
        n.data.slice(n === range.startContainer ? range.startOffset : 0, n === range.endContainer ? range.endOffset : n.data.length)).join('');
      const wrapRange = (range, id) => {
        const nodes = textNodes().filter(n => range.intersectsNode(n));
        for (const node of nodes) {
          const start = node === range.startContainer ? range.startOffset : 0;
          const end = node === range.endContainer ? range.endOffset : node.data.length;
          if (end <= start || !node.data.slice(start, end).trim()) continue;
          let target = node;
          if (start > 0) target = target.splitText(start);
          if (end - start < target.data.length) target.splitText(end - start);
          const mark = document.createElement('mark');
          mark.setAttribute('data-yab-hl', id);
          mark.setAttribute('style', STYLE);
          target.parentNode.insertBefore(mark, target);
          mark.appendChild(target);
        }
      };
      window.__yabHL = {
        wrap() {
          const sel = window.getSelection();
          if (!sel || sel.isCollapsed || !sel.rangeCount) return { none: true };
          const range = sel.getRangeAt(0);
          const anchor = range.commonAncestorContainer;
          const el = anchor.nodeType === 1 ? anchor : anchor.parentElement;
          const inside = el && el.closest('mark[data-yab-hl]');
          if (inside) {
            const id = inside.getAttribute('data-yab-hl');
            this.unwrap(id);
            sel.removeAllRanges();
            return { removed: id };
          }
          const text = textOf(range);
          if (!text.trim()) return { none: true };
          const { text: all, spans } = flat();
          let at = -1;
          if (range.startContainer.nodeType === 3) {
            for (const [from, n] of spans) if (n === range.startContainer) { at = from + range.startOffset; break; }
          }
          if (at < 0) at = Math.max(0, all.indexOf(text));
          const prefix = all.slice(Math.max(0, at - 32), at);
          const suffix = all.slice(at + text.length, at + text.length + 32);
          const id = 'h' + Date.now().toString(36) + Math.random().toString(36).slice(2, 6);
          wrapRange(range, id);
          sel.removeAllRanges();
          return { added: { id, text, prefix, suffix } };
        },
        unwrap(id) {
          document.querySelectorAll('mark[data-yab-hl="' + id + '"]').forEach(m => {
            const parent = m.parentNode;
            while (m.firstChild) parent.insertBefore(m.firstChild, m);
            parent.removeChild(m);
            parent.normalize();
          });
        },
        clear() {
          const ids = new Set([...document.querySelectorAll('mark[data-yab-hl]')].map(m => m.getAttribute('data-yab-hl')));
          ids.forEach(id => this.unwrap(id));
          return ids.size;
        },
        restore(items) {
          let found = 0;
          for (const h of items) {
            if (document.querySelector('mark[data-yab-hl="' + h.id + '"]')) { found++; continue; }
            const { text: all, spans } = flat();
            const whole = all.indexOf(h.prefix + h.text + h.suffix);
            const from = whole >= 0 ? whole + h.prefix.length : all.indexOf(h.text);
            if (from < 0) continue;
            const r = rangeAt(spans, from, from + h.text.length);
            if (!r) continue;
            wrapRange(r, h.id);
            found++;
          }
          return found;
        }
      };
    }
    """#
}
