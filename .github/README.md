<p align="center"><img src="../Icon/KoanMark.png" width="120" alt="Koan"></p>

# Koan

My version of [Yab](https://github.com/yetanotherbrowser/yab), an Arc-like Mac browser. I really liked Yab but wanted it to feel more like Zen, as I think it misses a few things (such as having the address bar on top AND the sidebar both autohiding), so I forked it and kept going.

What's different:

- The address bar sits on the window itself like on Zen.
- Focus mode blocks the sites that consume your time and you can lock it so turning it off isn't one click away. App blockers and Shortcuts can turn it on and lock it too: `open -g "yab-focus://lock?minutes=50"`.
- Aria2 is integrated for downloads : big files come in faster (parallelization) and torrents and magnet links work out of the box.
- Smaller things: web panels next to the page, highlights that stay on pages, only one tab playing sound at a time, downloads sorted into folders, idle tabs put to sleep to save memory.

Pages run in WebKit and any site that needs it can use Chromium instead (You can change that if you want though). No account and nothing to sign in to.

## Getting it

Builds will go up under [Releases](https://github.com/hczr-dev/koan/releases). Until then you can build it yourself with Xcode 26:

```bash
git clone https://github.com/hczr-dev/koan.git
cd koan
scripts/custom/build-dev.sh
open build/Koan.app
```

Yab's updates are pulled daily via a Github CI (which is basically why some of Yab's strings persist to avoid conflicts with the upstream version) with `scripts/custom/sync-upstream.sh`.

## Credit

Almost all of this is Yab's work. Koan is a fork under the same Apache 2.0 license. It isn't affiliated with or endorsed by Yab, and "Yab" is their trademark ([TRADEMARKS.md](../TRADEMARKS.md)).
