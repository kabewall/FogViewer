# FogViewer

A macOS app that shows your [Fog of World](https://fogofworld.app/) records as fog on a map.

FogViewer reads the Fog of World Sync folder in your iCloud Drive directly and draws the places you have visited as clear areas in the fog. It also keeps a history of how the fog changes, so you can replay your exploration over time.

> [!NOTE]
> This is an unofficial tool. It is not affiliated with or endorsed by Fog of World or its developer. It relies on an undocumented file format and may stop working if Fog of World changes it.
>
> The user interface is in Japanese.

## Features

- **Fog map** — Renders your Fog of World records over Apple Maps, with adjustable fog color, opacity, and minimum line width.
- **History** — A background agent (launchd) watches the Sync folder and stores each change as a diff in SQLite.
- **Backfill** — Fills in when each place was first visited, using GPX files and Google Timeline exports (iOS and Android formats).
- **Timelapse** — Replays how the fog cleared over time.
- **Region ranking** — Shows how much of each country, and of each Japanese prefecture and municipality, you have explored.

## Requirements

- macOS 15 or later
- Xcode 16 or later
- Fog of World with iCloud sync enabled on the same Apple Account

## Build

Open `FogViewer.xcodeproj` in Xcode and run the `FogViewer` scheme.

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen). After changing `project.yml`, run:

```sh
xcodegen generate
```

To run the tests:

```sh
xcodebuild test -scheme FogViewer -destination 'platform=macOS'
```

Tests that read real data are skipped when no Fog of World Sync folder is found.

## Usage

FogViewer reads your records from:

```
~/Library/Mobile Documents/iCloud~com~ollix~FogOfWorld/Documents/Sync
```

It only reads from this folder and never writes to it. On first access, macOS may ask for permission to read another app's iCloud data.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘R | Reload from iCloud |
| ⌘0 | Show all records |
| ⇧⌘F | Show or hide the fog |
| ⇧⌘T | Start the timelapse |
| ⇧⌘R | Open the region ranking |
| ⌘, | Settings (history, imports, backfill) |

### Command-line options

| Option | Description |
|---|---|
| `--watch` | Check the Sync folder once, record any changes, and exit. Used by the launchd agent. |
| `--backfill` | Run the backfill from imported GPX and Timeline files without opening a window. |
| `--collapse-purge <ID…>` | Merge consecutive iCloud history events into one net change, and remove the bits that disappeared from the whole history. Useful for cleaning up an erroneous track. |

### Data

All data stays on your Mac. FogViewer stores its data in `~/Library/Application Support/FogViewer/`:

- `history.sqlite` — the change history
- `backups/` — zip snapshots of the Sync folder, taken when a change is recorded
- `imports/` — GPX and Timeline files you have imported

## Region data

`FogViewer/Resources/regions.bin` contains simplified boundaries built with `tools/build_regions.sh` from:

- [Natural Earth](https://www.naturalearthdata.com/) 1:10m Admin 0 – Countries (public domain)
- 「国土数値情報（行政区域データ）」（国土交通省）, N03, as of January 1, 2026 ([source](https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N03-2026.html)), licensed under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The data was simplified, merged by municipality, and converted to a custom binary format.

`regions.bin` is distributed under the terms of these sources, not under the MIT License.

## Acknowledgments

Thanks to [Fog Machine](https://github.com/CaviarChen/fog-machine) for documenting the Fog of World tile format.

## License

The source code is released under the [MIT License](LICENSE). See [Region data](#region-data) for the license of `regions.bin`.
