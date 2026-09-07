# MogWatch

A Windower 4 addon + desktop viewer that shows your live player and party
status on a second screen. Originally sparked by the ideas in the Ashita
addon [VanaDeck](https://github.com/Zensenshi/Vanadeck), but MogWatch is its
own project from here: its own wire protocol, its own name, and it won't
talk to the VanaDeck app or vice versa.

## Testing on Windows first (no phone needed)

`mogwatch_viewer.py` is a small standalone desktop window that speaks
MogWatch's UDP status protocol directly — no pairing needed, since it talks
to loopback (127.0.0.1) the same way the addon does by default.

1. Install Python 3 if you don't have it (python.org, check "Add to PATH"
   during install).
2. Run: `python mogwatch_viewer.py` (add `--port 9090` if you changed the
   addon's port).
3. Drag the window to your second monitor.
4. Load the Windower addon as below. The viewer should start filling in
   within a second or two.

It's deliberately plain (Tkinter) — PNG/GIF/PPM/PGM map images work with no
extra installs. For JPEG/BMP/TIFF/WEBP map images, install Pillow once with
`pip install Pillow`. Once this is eventually packaged as a standalone
`.exe` (see the "Building a standalone .exe" section below), Pillow gets
bundled in automatically and end users won't need to install anything at
all, for any format.

## Install (Windower addon)

1. Create a folder `mogwatch` inside your Windower `addons/` directory.
2. Put `mogwatch.lua` inside it.
3. In game: `lua load mogwatch` (or add that line to your startup script).

## Usage

```
//mogwatch                  -- show current bridge target/state
//mogwatch host <address>   -- set the viewer's IP (loopback needs no pairing)
//mogwatch port <number>    -- set the bridge port (must match the viewer)
//mogwatch pair <code>      -- pair using a code from a networked viewer
//mogwatch unpair           -- clear pairing
```

Defaults to `127.0.0.1:8080`. If the viewer is on the same machine (or same
Winlator container), no pairing is required. Pairing/encryption only kicks
in once you point it at a non-loopback address — for a future networked
Android viewer, for instance.

## What works

- Pairing/encryption handshake (ChaCha20 + HMAC-SHA256) for non-loopback use.
- Binary UDP status frames with your live player vitals, job/subjob, HP/MP/TP,
  position, and active buffs (names only, no timers yet).
- Party member vitals (HP/MP %) for party members in your zone.
- **Target frame**: current target's name, HP%, and distance (computed from
  raw X/Z coordinates, not from a `mob.distance` field I couldn't confirm
  the units of).
- **Map browser**: a separate window (the viewer's "Open Map" button) that
  shows whichever map image(s) you've supplied for the zone you're
  currently in. This is a plain image viewer — auto-picks the right file,
  lets you zoom and pan — **it does not show your live position or do any
  calibration**. Earlier versions of this tool tried to overlay a live
  position dot with click-to-calibrate coordinate mapping; that turned out
  to be persistently unreliable in practice and has been removed in favor
  of something simple that just works. Nothing here downloads, bundles, or
  reproduces Square Enix's (or anyone else's) map art — you supply the
  images.
  - **Auto-discovery**: drop images into a `Maps` folder next to the
    script, named to match the zone:
    ```
    Maps/Bastok Markets.png              <- single map, no suffix needed
    Maps/Beadeaux - Map 1.png            <- multi-map area, first map
    Maps/Beadeaux - Map 2.png            <- second map
    Maps/Beadeaux - Map 1 v2.png         <- an alternate version of Map 1
                                             (e.g. different info drawn on it)
    ```
    MogWatch matches the "area name" part against the zone you're
    currently in (case/whitespace-insensitive, everything else must match
    exactly — e.g. apostrophes in names like "Ru'Lude Gardens" matter).
    When it finds more than one map (or more than one version of the same
    map) for the same area, the "Map:" dropdown shows all of them, sorted
    by map number then version, plus a "(N maps found)" note so it's
    obvious there's more than one. Click "Rescan Maps Folder" if you add
    files while the window's open.
  - **Auto-fit to window**: the map image scales to fit however you've
    sized the window, preserving its original aspect ratio (never
    stretched unevenly) — resize the window and it rescales live. Use
    "+/−" to zoom in manually (switches out of auto-fit), and "Fit to
    Window" to snap back to auto-sizing. Ctrl+scroll wheel also zooms
    manually.
- A redesigned viewer: colored HP/MP/TP bars, a target panel, low-HP party
  rows highlighted in red.
- Sending chat/macro text from a connected viewer into the game (via
  `windower.chat_input`).
- **Nearby NPCs** ("Nearby NPCs" button): a plain list of nearby
  NPCs/monsters — name, distance, HP% — using Windower's `get_mob_array()`.
  Filtered to within 50 units and capped at the 15 closest to keep frames
  small. No map involved, just a list.
- **Chat log relay** ("Chat Log" button): incoming and outgoing chat lines
  relayed to the viewer via `incoming text` / `outgoing text`. This is
  best-effort — it rides the same UDP status frames as everything else, so
  a dropped packet means a dropped line. Fine for a glance-at-it companion
  display; not a substitute for the game's own chat log if you need every
  line guaranteed. Channel names aren't translated (shown as "Mode N")
  since I don't have a verified complete mode-to-channel-name table — easy
  to add once confirmed. The outgoing-side event signature is also a
  best-effort match to common patterns rather than something I could fully
  verify, so if outgoing lines don't show up correctly, that's the first
  thing to check.
- **Real buff timers**, shown as `Protect (25:23)` next to each buff name.
  This hooks packet `0x063` (sub-type `0x09`, StatusIcons) directly and
  decodes the actual byte layout — confirmed against LandSandBoat's real
  packet source (`0x063_miscdata_status_icons.h/.cpp`), not guessed. The
  timer conversion itself was derived from LandSandBoat's `earth_time.h`:
  the server encodes an absolute expiry value as
  `(seconds_remaining + vanadiel_timestamp()) * 60`, deliberately
  overflowed into 32 bits, where `vanadiel_timestamp()` — despite the name
  — turns out to be plain real seconds since a fixed custom epoch (Unix
  time `1009810800`), not scaled to Vana'diel's 25x clock. Knowing that
  exact epoch and formula, the addon computes what the packet *would* read
  at the instant of expiry using its own clock, and the difference (correctly
  unwrapped across the 32-bit overflow) gives real seconds-remaining. I
  verified this end-to-end with simulated buff lifecycles, including
  specifically forcing a case that crosses the 32-bit wrap boundary, before
  shipping it — but it's still worth confirming against a real long-running
  buff, since simulation can't catch every real-world edge case (server
  clock drift, a private server with a manually adjusted time offset, etc).

## What's not built yet

- **Live position on the map** — deliberately removed; see above.
- **Cast bar** — needs a verified `action` event category mapping for
  cast-start detection, which I couldn't find or verify through
  documentation search. If you have a working reference for this (a Lua
  addon, or the relevant LandSandBoat/client packet source), send it over.
- **Macro book display + remote macro execution** — needs a way to read the
  macro slot text, which requires memory offsets I don't have verified.
  Once you have that, firing it is just running the lines via
  `windower.chat_input`.
- **EXP tracking, out-of-zone party job info** — party job data isn't in
  `get_party()` and needs the party sync packet.
- **Ctrl+Arrow subtarget paging** — possible via Windower's `keyboard` event
  (DirectInput scan codes), not implemented.

The status-frame plumbing (encoding, encryption, connection handling) is all
in place, so each item above is mostly "read the right Windower data and
drop it into `build_status()`."

## A note on coordinates

FFXI's horizontal ground plane is **X/Z** — **Y is vertical height**, not a
second ground axis. The addon reports `locationX` / `locationZ` (with a
separate `elevation` for height). This still matters for the target-distance
calculation even though the map no longer plots live position.

## Building a standalone .exe

`mogwatch_viewer.py` is a plain Python script by default — people running
it need Python installed. To distribute a standalone `.exe` that needs no
Python install at all:

1. `pip install pyinstaller pillow` (Pillow needs to be installed on the
   machine you *build* on, so PyInstaller can bundle it into the .exe --
   after that, end users need nothing extra for JPEG/BMP/TIFF/WEBP maps).
2. Run `build_exe.bat` (included alongside this README, in the same
   folder as `mogwatch.lua`), or directly:
   ```
   pyinstaller --onefile --windowed --name MogWatch --icon=mogwatch.ico mogwatch_viewer.py
   ```
3. The finished `MogWatch.exe` is in the `dist` folder. It looks for its
   `Maps` folder and settings files right next to itself, same as the
   script does — this already works correctly since the code resolves its
   own location via `sys.executable` when frozen, not `__file__` (which
   would otherwise point into PyInstaller's temporary extraction folder
   instead of next to the real .exe).

No further code changes are needed for this — it's already written to
work correctly once packaged.

**Icon**: `mogwatch.ico` (included) is a proper multi-resolution Windows
icon converted from the moogle artwork, embedded into the built `.exe`
via the `--icon` flag above. The running app also sets it as the window/
taskbar icon directly (works even before packaging, running the plain
`.py` script) — it just needs to sit in the same folder either way.

## Update checking

The app checks GitHub's public releases API a couple seconds after
startup and shows a small clickable banner if a newer version is
available — clicking it opens the release page in your browser so you
can download it yourself. This is intentionally **not** a fully silent
self-updating installer: a running `.exe` can't overwrite itself on
Windows without a separate updater process, which adds real complexity
and risk (partial downloads, verifying what got downloaded, handling a
failed replace) that isn't worth it for a tool like this. Manually
downloading a new release and replacing the old `.exe` is simple and
familiar, and this just tells you when there's a reason to.

**Setup needed**: open `mogwatch_viewer.py` and fill in `GITHUB_REPO`
near the top (currently `'YOUR_GITHUB_USERNAME/mogwatch'`) once the repo
exists, e.g. `'yourname/mogwatch'`. Until that's filled in, the update
check is skipped entirely — no network call, no error, just silently
does nothing, so it's safe to ship before the repo is live. Also bump
`MOGWATCH_VERSION` with each release, and tag GitHub releases to match
(e.g. a release tagged `v1.1.0` when `MOGWATCH_VERSION = '1.1.0'`).

The check fails silently on any error (no internet, GitHub rate limits
unauthenticated requests to 60/hour per IP, the repo not existing yet,
etc) — this is a background convenience feature and should never
interrupt normal use or show an error for something this minor.

## Counter tab (merged directly into mogwatch.lua)

The "Counter" button in the viewer shows drop/gil/item tracking that used
to be a separate addon (**Counter**, by wisdomcheese4) and is now merged
directly into `mogwatch.lua` — there is no separate `counter.lua` file
anymore, and nothing else to load. `//lua load mogwatch` (or whatever's
already in your `init.txt`) is all that's needed.

**Both command prefixes work identically**: `//counter ...` and
`//cnt ...` are registered as additional aliases on the same merged
addon, alongside `//mogwatch ...` — all three route to the same command
handler, dispatched by whichever subcommand word you actually typed (e.g.
`//counter add <item>` and `//mogwatch add <item>` behave identically,
since it's genuinely one addon now).

**What changed doing the merge:**
- Counter's own native on-screen display (the draggable in-game text
  panel, its context menu, mouse-click handling) was removed entirely —
  the MogWatch Counter tab replaced it as the only display. State is read
  fresh into the tab from `build_counter_status()`, called every time
  `build_status()` builds a regular status frame (same ~5x/second cadence
  as everything else in the main viewer), rather than needing its own
  separate refresh trigger the way the native display did.
- Session-clock tracking was removed entirely, per request — the state
  variables, its settings fields, the display row, the reset command, and
  its context-menu entry are all gone.
- `//counter show` / `//counter hide` no longer toggle a native window
  (there isn't one); they just point you at the MogWatch tab instead.
- Everything else — item drops, personal drops, usable items, equipped
  ammo, key items, gil, sets, auto-add toggles, quiet mode, focus item,
  debug commands, chat-message detection patterns — is the same
  already-working code, untouched. None of the detection/parsing logic
  was rewritten; only the display layer and command-dispatch plumbing
  changed to fit into one addon.

**What's not in the MogWatch tab specifically:** the native display's
drag-to-reposition and right-click-to-remove interactions aren't
reproduced there — the tab shows the same data with buttons instead
(Add, Remove, Reset, auto-add toggles, Quiet, Focus, Sets).

**A note on how thoroughly this was checked**: merging two addons'
command dispatch and load-time state together is exactly the kind of
change where a subtle reference bug can hide behind a clean syntax check.
Before shipping this, the merged file's full top-level initialization was
actually executed (not just syntax-checked) against a stubbed Windower
environment, and `build_counter_status()` / the command handler were
specifically exercised together — confirming a tracked item added via a
command genuinely shows up in the next status snapshot, not just that
neither function crashes in isolation. A couple of real bugs turned up
doing this (a stale forward-declaration that would have silently broken
~45 call sites, and a function-ordering issue where one part of the merge
couldn't see another) and were fixed before this reached you.
