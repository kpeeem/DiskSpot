# DiskSpot — details

English · [Русский](details.ru.md)

## Advice outside the home folder

`disk_system` measures system caches and logs, temp folders, simulators, Homebrew, Docker and apps not launched for months. The agent sends either a path (caches and temp files with any verdict; apps and vendor folders in `/Library` only *review*; `/System`, `/usr`, `/opt/homebrew` and system configuration refused) or an allowlisted action: `brew-cleanup`, `brew-uninstall-cask`, `simctl-delete-unavailable`, `simctl-delete-device`, `simctl-runtime-delete`, `docker-prune`, `empty-trash`. Action rows show the exact command and a «Выполнить…» (Run) button. Items owned by the system go to the Trash through Finder, which asks for an administrator password.

## How it counts

1. **Spotlight.** A `kMDItemPhysicalSize` query returns big files and bundles in seconds; folder sizes are summed by path.
2. **Blind spots.** Whatever Spotlight does not index (exclusions, system and service folders) is walked exactly.
3. **Exact walk.** A shared folder queue keeps every thread busy; entries come in batches from `getattrlistbulk` (`readdir` as a fallback), blocks are counted like `du`, hard links and APFS clones once (advice sizes count only what deleting would free), mount points are not crossed, iCloud placeholders are never downloaded. Only folders and files above the threshold are kept; the folded tree is built bottom-up.

| Scanned (under load) | Files | Previous walk | Folder queue |
|---|---:|---:|---:|
| `Xcode.app/Contents/Developer` | 126,457 | 1.0–1.8 s | 0.4–0.8 s |
| a developer folder | 3.5 M | 34.5 s | 28.7 s |
| the whole `/System/Volumes/Data` | 9.2 M | 232 s | 137 s |

## MCP tools

| Tool | What it does |
|---|---|
| `disk_volumes`, `disk_status` | volumes with used, free and purgeable space; APFS system volumes; access and Spotlight exclusions |
| `disk_tree`, `disk_top` | exact tree and the heaviest folders and files under a path |
| `disk_big_files`, `disk_recent` | big files and what was written in the last days, straight from the Spotlight index |
| `disk_snapshot`, `disk_diff`, `disk_snapshot_forget` | store a measurement and see what grew, appeared or went away since |
| `disk_system` | what takes space outside the home folder, and the allowed actions |
| `disk_advise`, `disk_advice`, `disk_advice_clear`, `disk_show_cleanup` | send advice to the app, read what the user did, clear it, open the tab |

The whole boot volume is `/System/Volumes/Data`: `/` is the sealed system volume and the walk never crosses mount points.

## Debugging

```sh
./build.sh Debug
```

```sh
open -n --env DISKSPOT_FOLDER=/Applications --env DISKSPOT_SNAPSHOT=/tmp/diskspot --env DISKSPOT_DEMO=1 --stderr /tmp/diskspot.log build/DiskSpot-Debug.app
```

`DISKSPOT_FOLDER` opens a folder, `DISKSPOT_DEMO` hides external volumes and the access prompt, `DISKSPOT_EXACT`, `DISKSPOT_ZOOM`, `DISKSPOT_SELECT` and `DISKSPOT_PROBE` start an exact walk, a zoom, a selection and a scanner probe.

`Scripts/screenshots.sh` rebuilds the README screenshots from a synthetic home folder (`Scripts/demo-home.py`), so they never show real files.
