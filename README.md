# DiskSpot

[![Release](https://img.shields.io/github/v/release/kpeeem/DiskSpot)](https://github.com/kpeeem/DiskSpot/releases/latest)
[![License](https://img.shields.io/github/license/kpeeem/DiskSpot)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)

English · [Русский](README.ru.md)

> **TL;DR** — A SwiftUI disk-space analyzer that answers in seconds from the Spotlight index and walks exactly only what Spotlight can't see. Treemap, tree with shares, file kinds, a cleanup tab, and an MCP server so Claude can measure your disk and send cleanup advice into the app. The interface is in Russian.

![DiskSpot: home folder treemap, tree and file kinds](Docs/diskspot.jpg)

## Install

1. Download `DiskSpot-*.zip` from [Releases](https://github.com/kpeeem/DiskSpot/releases/latest) and move the app to Applications.
2. The build is not notarized. On first launch open **System Settings → Privacy & Security → Open Anyway**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/DiskSpot.app
```

3. Give it **Full Disk Access**: without it Desktop, Documents, Downloads and parts of Library are hidden from both Spotlight and the walk.

Build from source (Xcode and `brew install xcodegen`):

```sh
git clone https://github.com/kpeeem/DiskSpot.git && cd DiskSpot && ./build.sh && open build/DiskSpot.app
```

## What it does

- **Spotlight first.** Big files and bundles come from the index in seconds; blind spots are walked exactly.
- **Exact when needed.** Parallel `getattrlistbulk` walk counts like `du`: the whole data volume, 9 million files, in about two minutes.
- **Watch growth.** Snapshots and diffs show what grew since last time.
- **Уборка (Clean Up).** Claude's advice plus caches, logs, DerivedData and package caches DiskSpot measures itself.

![Cleanup tab with Claude's advice](Docs/cleanup.jpg)

## Ask Claude what to clean

```sh
./build-mcp.sh && claude mcp add --scope user diskspot "$PWD/build/diskspotmcp"
```

Then ask *“what filled my disk lately, what can I delete?”*. Claude answers from `disk_recent`, `disk_top` and `disk_system` and sends each finding with a verdict and a reason; you tick what goes, Claude reads back what you did. The advice is shared with [Disk Inventory](https://github.com/kpeeem/DiskInventory).

> [!IMPORTANT]
> The agent never deletes anything. Paths go to the Trash only after you confirm. Commands come from a fixed allowlist (`brew cleanup`, `simctl delete`, `docker prune`…), and the app shows the exact command before running it. `/System`, `/usr` and system settings are refused.

More: [how it counts, MCP tools, benchmarks, debugging](Docs/details.md)

## License

[MIT](LICENSE)
