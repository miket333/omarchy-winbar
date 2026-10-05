# Winbar

A Windows-style taskbar for the [Omarchy](https://omarchy.org/) bar.

One icon per app on the current workspace, with **live window thumbnails** on
hover. Unlike a plain launcher, Winbar shows you what each window actually looks
like before you commit to it — then focuses it, toggles it maximized, or closes
it, without moving your cursor.


## Features

- **Live thumbnails** — hovering an icon opens a preview per window of that
  app, captured through Hyprland's toplevel export. The preview follows the bar:
  a row alongside a horizontal bar, a stack alongside a vertical one.
- **Windows-style previews** — the app icon and window title sit above each
  thumbnail.
- **Hover-close** — hovering a thumbnail highlights it and reveals an **X** in
  its upper-right, so a window can be closed without opening the menu.
- **Click to switch** — clicking a thumbnail focuses that window and fills the
  screen with it; clicking the window already filling the screen puts it back in
  the layout. The pointer stays exactly where you clicked.
- **Pin shelf** — pin apps to the bar as quick-launch targets. A pinned app with
  no window appears dimmed and launches on left-click.
- **App identity** — windows are grouped by the app they represent, not just
  the window class. A terminal running `cliamp` gets its own `cliamp` icon
  instead of grouping under Foot, and a browser web-app window (a Discord PWA,
  say) is identified by its title, so it shows the app's own icon and gets its
  own button. Multiple windows of the same app still share one icon.
- **Running indicator** — the count badge shows `1` for a single window, `2` for
  a pair, and so on, so you can see at a glance what is running.
- **Drag to reorder** — drag an icon to a new slot; a magnified copy of the
  icon follows the pointer and an insertion bar marks where it will land. The
  order persists, so your pinned apps keep the arrangement you gave them.
- **Management menu** — right-click an icon or a thumbnail for Focus, Maximize /
  restore, New window, Pin / Unpin, Close, Close other windows, and Close all.
  Right-clicking a thumbnail keeps the previews up and centres the menu on that
  thumbnail; closing the window drops its thumbnail.
- **Settings popup** — right-click → Settings… to tune thumbnail size, how many
  thumbnails show per app, bar icon size, and whether thumbnails are shown.
- **Orientation-aware** — works on the bar in any position.

## Install

```bash
omarchy plugin add https://github.com/miket333/omarchy-winbar.git --enable
omarchy bar move io.github.miket333.winbar --section left --after omarchy.workspaces
```

Requires Omarchy 4+ and Hyprland 0.56+ (the Lua dispatcher API).

## Usage

| Input | What it does |
|---|---|
| **Hover an icon** | Opens the window thumbnails for that app |
| **Left-click a thumbnail** | Focus that window and fill the screen with it (again to restore) |
| **Right-click a thumbnail** | Open the management menu centred on that thumbnail (previews stay up) |
| **Hover a thumbnail, click the X** | Close that window |
| **Left-click a pinned, closed app** | Launch it |
| **Middle-click an icon** | Close that app's focused window |
| **Right-click an icon** | Open the management menu |
| **Drag an icon** | Move it to a new position in the strip |

## Configuration

Settings are stored inline on the widget's entry in
`~/.config/omarchy/shell.json`, which the shell hot-reloads on save. The Settings
popup on the bar writes to the same place.

| Key | Default | Meaning |
|---|---|---|
| `iconSize` | `18` | Bar icon edge length in pixels |
| `thumbnailWidth` | `220` | Thumbnail width in the preview |
| `maxThumbnails` | `6` | Thumbnails shown per app before "+N more" |
| `showThumbnails` | `true` | Show the hover previews at all |
| `pinned` | `""` | Comma-separated app ids pinned to the bar |
| `order` | `""` | Comma-separated display order set by dragging icons |

> **Disabling the widget discards its settings.** Omarchy stores bar-widget
> settings inline on the bar layout entry, and disabling removes that entry.

## How it works

Each window is resolved to the app it represents before grouping. The window
class is matched against the desktop entries first; for terminals (their class
names the emulator, not what is running inside) and for browser app / PWA
windows (their class is synthetic) the window title is matched to a desktop
entry's name instead. Titles are matched a segment at a time as well as whole,
so a window titled `Home / X` or `Discord | #general` resolves to X or Discord
and picks up that app's icon. Anything unresolved falls back to the class, and
an icon name the theme cannot resolve draws the generic application icon rather
than leaving an empty slot. The resolved icon and identity are what the strip
draws and groups by.

Window actions go out as Hyprland Lua dispatchers, because Hyprland 0.56 dropped
the string dispatcher API and Quickshell's native `Toplevel.activate()` is not
honoured by Hyprland.

Focusing a window normally makes Hyprland warp the pointer to its centre
(`cursor:no_warps` defaults to `false`). Winbar reads the pointer position,
focuses, and puts the pointer back, all inside one dispatch, so a thumbnail
click leaves the cursor where it was. See the comments in `Taskbar.qml`.

## Remove

```bash
omarchy plugin remove io.github.miket333.winbar
```

## License

MIT — see [LICENSE](LICENSE).
