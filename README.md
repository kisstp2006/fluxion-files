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

## What is there

- Windows 11's window: tabs in the title bar (Ctrl+T, Ctrl+W, Ctrl+Tab, a
  tab's own menu), the command bar - New, cut, copy, paste, rename, share,
  delete, Sort, View, "···", Details - framed by the compositor through
  `fluxion_window_v1`: rounded corners, shadow, and the layout picker on
  the maximise button.
- Windows 10's: its own title bar with the Quick Access Toolbar, the
  ribbon - File, Home, Share, View, and the tabs for what is shown:
  Recycle Bin Tools, Picture Tools, Drive Tools, Search Tools - no tabs.
- The address bar as crumbs - each "›" lists the folders to go to - or a
  path to type (F4, Ctrl+L, Alt+D); the search box its twin. Back,
  forward, recent locations, up, refresh.
- The navigation pane as a tree: Home or Quick access, the person's folders
  and GTK's bookmarks as pins, the Recycle Bin, This PC with the drives,
  Network; any folder opens to the folders in it.
- Home and This PC pages; folders in Details, List, Extra large to Small
  icons, Tiles and Content (Ctrl+Shift+1…8), only what is in sight laid
  out; photos as themselves in the large views, from the system's
  thumbnail cache or the file, made on a thread.
- Group by name, date, type or size, each group folded by its heading;
  check boxes; a rubber band to choose with; Compact view.
- Search under the folder shown, on a thread, the list filling as it finds.
- The Recycle Bin (the XDG trash): where each item was and when it was
  deleted; restore, delete for good, empty.
- The details and preview panes (Alt+Shift+P, Alt+P); Properties
  (Alt+Enter): General and Security, read-only and permissions to change.
- Right-click menus as Windows has them: Windows 11's with its glyph row
  and "Show more options", Windows 10's classic one - Open with, Send to,
  Create shortcut, Copy as path, Open in Terminal, Pin to Quick access,
  Compress to ZIP file; View, Sort by, Group by and New beside.
- Sorting as Windows sorts (folders first, numbers by value), hidden items
  and extensions shown or not, selection with Ctrl, Shift and the keyboard,
  type-ahead, rename (F2, or a click on the one chosen), files opened in
  their default app (`mimeapps.list`).

## Licence

BSD-2-Clause, as the rest of Fluxion.
