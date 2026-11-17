<p align="center"><img src="../Icon/KoanMark.png" width="120" alt="Koan"></p>

# Koan

My take on [Yab](https://github.com/yetanotherbrowser/yab), the Mac browser. I liked Yab but wanted it to feel more like Zen, so I forked it and kept going.

What's different:

- The address bar sits on the window itself, Zen style. With auto-hide on, it slides down from the top when you need it and gets out of the way when you don't.
- Focus mode blocks the sites that eat my day, and you can lock it so turning it off isn't one click away. App blockers and Shortcuts can turn it on and lock it too: `open -g "yab-focus://lock?minutes=50"`.
- Downloads go through aria2 by default, so big files come in faster. Torrents and magnet links work too.
- Lighter when idle: Chromium only runs while a page needs it and shuts down a few minutes after the last one closes (that's 250 to 350 MB back), and the see-through window blur is only live in the window you're using.
- Smaller things: web panels next to the page, highlights that stay on pages, only one tab playing sound at a time, downloads sorted into folders, idle tabs put to sleep to save memory.

Pages run in WebKit, the engine Safari uses, and any site that needs it can go to Chromium instead. No account, nothing to sign in to.

## Getting it

Download the latest zip from [Releases](https://github.com/hczr-dev/koan/releases), unzip it and drag Koan into Applications. It isn't notarized yet (no Developer ID), so the first time you open it, right-click Koan and choose Open, or allow it under System Settings › Privacy & Security.

Two things about the download: its Chromium is the official CEF build, which leaves out H.264 and AAC (WebKit tabs, the default, play everything), and Smart Downloads uses aria2 from Homebrew (`brew install aria2`) since it isn't bundled.

Or build it yourself with Xcode 26:

```bash
git clone https://github.com/hczr-dev/koan.git
cd koan
scripts/custom/build-dev.sh
open build/Koan.app
```

Yab's main branch is merged in every night by a GitHub Action; on a Mac, `scripts/custom/sync-upstream.sh --build` pulls that and rebuilds. If Koan is open, the new build waits next to it and takes its place when you quit.

## Credit

Almost all of this is Yab's work. Koan is a fork under the same Apache 2.0 license, and my changes are in the git history. It isn't affiliated with or endorsed by Yab, and "Yab" is their trademark ([TRADEMARKS.md](../TRADEMARKS.md)).
