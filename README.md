# Fluxion Files

The file manager of [Fluxion Desktop](../fluxion-de): it works like the file
manager of Windows 11 - and of Windows 10 when the desktop has that look -
and follows the desktop's settings (light or dark, the accent, the Windows
11 or 10 look, corners, transparency) live, as Settings does.

The whole design, the research behind it and the milestones are in
`fluxion-de/docs/FILES.md`.

```bash
zig build run                      # Home
zig build run -- ~/Documents       # a folder
zig build test
tools/install.sh                   # into /usr/local, as the desktop's file manager
```

## What is there (M1, in progress)

- Windows 11's window: tabs in the title bar (Ctrl+T, Ctrl+W, Ctrl+Tab),
  framed by the compositor through `fluxion_window_v1` - rounded corners,
  shadow, and the layout picker on the maximise button.
- Windows 10's: the compositor's title bar, the ribbon, Quick access, the
  light-blue selection, no tabs.
- The address bar as crumbs, or a path to type (F4, Ctrl+L, Alt+D); back,
  forward, up, refresh (Alt+Left, Alt+Right, Alt+Up, F5, Backspace).
- The navigation pane: Home, the person's folders, GTK's bookmarks as pins,
  This PC with the drives, Network.
- Home and This PC pages; folders in Details, List, Extra large to Small
  icons, Tiles and Content (Ctrl+Shift+1…8), only what is in sight laid
  out.
- Sorting as Windows sorts (folders first, numbers by value), hidden items
  and extensions shown or not, selection with Ctrl, Shift and the keyboard,
  type-ahead, files opened in their default app (`mimeapps.list`).

## Licence

BSD-2-Clause, as the rest of Fluxion.
