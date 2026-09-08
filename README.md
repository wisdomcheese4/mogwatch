# MogWatch

MogWatch shows your character's live status — HP, MP, TP, buffs, party,
nearby enemies, chat, and item/gil drop tracking — in a separate window
you can keep open on a second monitor while you play FFXI through
Windower. It's a [Windower 4](https://www.windower.net/) addon paired
with a small desktop app.

This guide walks through installing it and explains what each part does.

---

## 1. Installing the addon

1. Find your Windower installation folder, then go to
   `Windower4/addons/`.
2. Copy the `mogwatch` folder (containing `mogwatch.lua`) into that
   `addons` folder, so you end up with
   `Windower4/addons/mogwatch/mogwatch.lua`.
3. Start FFXI through Windower, and once you're logged in, type:
   ```
   //lua load mogwatch
   ```
4. You should see a message in the chat log confirming it loaded.

**To make it load automatically every time**, open (or create)
`Windower4/init.txt` and add a line:
```
lua load mogwatch
```

## 2. Installing the viewer (the window you actually look at)

The addon itself doesn't show anything on its own — it just sends data
to a small desktop app, which is what you'll actually watch. You have
two options:

### Option A: Standalone .exe (easiest, no setup)

If you have a `build_exe.bat` file, just double-click it. Nothing else to
install. Drag the window to your second monitor and leave it open while
you play.

### Option B: Running it with Python

If you don't have the `.exe`, you can run the viewer directly:

1. Install [Python 3](https://www.python.org/downloads/) if you don't
   already have it.
2. Open a command prompt in the folder containing `mogwatch_viewer.py`
   and run:
   ```
   python mogwatch_viewer.py
   ```
3. (Optional) For JPEG/BMP/TIFF/WEBP map image support, also run
   `pip install Pillow` first. PNG map images work either way.

Either way, as long as you're playing on the same computer, there's
nothing to configure — the addon and viewer find each other automatically
on `127.0.0.1`.

## 3. Confirm it's working

With FFXI running, the addon loaded, and the viewer open, you should see
your character's name, job, HP/MP/TP bars, and current zone appear in the
viewer within a couple seconds. If it stays blank, see
[Troubleshooting](#troubleshooting) below.

---

## What each part of the viewer shows you

### Main window: Player and Target

The main window is always visible and shows:

- **Player panel** — your name, job/subjob, HP/MP/TP bars (the HP bar
  changes color as it drops: green → yellow → orange → red, and flashes
  once critically low), your current zone, and two separate lists:
  **Buffs** (green text) and **Debuffs** (red text), each showing a
  live countdown timer where one is available.
- **Target panel** — whatever you currently have targeted: its name,
  an HP bar, and distance from you.

Down the left side are buttons that open additional windows:

### Party

Shows every party member's name, job/subjob, and colored HP/MP/TP bars.
Buffs and debuffs are shown too, separated into their own lines — though
only **your own** row will show a countdown timer next to each one, since
that timing information isn't available for other party members over the
network, only their identity. The window resizes itself to fit however
many people are actually in your party, and you can still resize it
manually at any time.

### Nearby NPCs

A list of nearby monsters/NPCs within range, sorted by distance, with
name, distance, and HP%. Rows for low-HP targets are highlighted red.

### Chat Log

A running log of your incoming chat (say, party, linkshell, tells,
system messages, etc.), so you can glance at conversation history without
tabbing back into the game. You can choose which chat channels show up
here from in-game with the `//mogwatch chatmode` command (see the command
reference below).

### Map

A simple map image browser. Put image files in a `Maps` folder next to
the viewer (or the `.exe`), named after the zone (e.g. `Bastok Mines
Markets.png` — see the note printed in the Map window itself for exact
naming rules, including how to handle zones with multiple maps). It
automatically shows the right image for whatever zone you're in, with
zoom and pan. It does **not** show your live position on the map — just
the image itself.

### Counter — item, gil, and drop tracking

This is the biggest feature, so it gets its own section below.

---

## Counter: tracking drops, gil, and farming progress

Click **Counter** in the main window to open this tab. It automatically
tracks:

| Category | How items get added |
|---|---|
| **Item Drops** | Auto-added when you get a monster drop (if turned on — see below), or added manually |
| **Personal Drops** | Auto-added from chests, NPCs, and quest rewards |
| **Usable Items** | Auto-added — potions, ethers, and similar consumables |
| **Equipped Ammo** | Automatic based on whatever's in your ammo slot — you can't add/remove this manually |
| **Key Items** | Auto-added, shown by name only |
| **Gil** | Tracked automatically once you've received any — the line only appears once you actually have gil to show |

**Reading the numbers**: each item shows two numbers, like
`Beastcoin  2 [5]`. The first number is how many you've gained *this
session* (since you opened the game or last reset it); the second,
bracketed number is how many you currently have in your inventory
(all bags combined) — not a running lifetime tally, your actual current
count.

**Color flashes**: an item's name briefly flashes green for 5 seconds
when it's newly added to the list, or when its count goes up; it flashes
red if the count goes down (used, sold, or traded away).

**Managing items**: click directly on an item's name to open a small
menu with **Reset Count** and/or **Remove**, depending on the category.

**Toggle buttons** (Drop / Personal / Usable / Gil / Quiet) show ON/OFF
status right in the button text, and clicking one flips it. **Item
Drops** auto-adding is off by default (so random junk drops don't
clutter your farming list) — turn it on, or just add specific items
you're farming with the **Add** box at the top.

**Quiet mode** suppresses the automatic chat messages Counter normally
prints every time it detects a drop — handy if you find them spammy.

**Clear All** wipes Item Drops, Personal Drops, Usable Items, and Key
Items entirely (Equipped Ammo is untouched, since it just reflects
whatever you have equipped). It asks for confirmation first, since this
can't be undone.

**Sets** let you save your current Item Drops / Personal Drops / Usable
Items list under a name, so you can quickly switch between different
farming setups. Loading a set replaces your Item Drops list but merges
in Personal Drops/Usable Items without wiping anything else you're
already tracking.

**Focus** pins one item name so you can keep an eye on a specific
farming target.

---

## Command reference

All of these are typed in the FFXI chat box. `//mogwatch`, `//counter`,
and `//cnt` all work interchangeably — they're the same addon.

### Connection
```
//mogwatch host <address>       Set the viewer's address (default: 127.0.0.1)
//mogwatch port <number>        Set the connection port (default: 8080)
```

### Tracking (Counter)
```
//counter add <item name>              Add an item to tracking
//counter add ItemA, ItemB, ItemC       Add several at once
//counter remove <item name>           Remove an item
//counter reset                        Reset all counters to 0
//counter resetitem <item name>        Reset just one item's counter
//counter clear                        Wipe all tracked lists (see Counter section above)
//counter list                         List everything currently tracked, in chat
```

### Auto-add toggles
```
//counter auto                         Show status of all categories
//counter auto drop on/off
//counter auto usable on/off
//counter auto personal on/off
//counter auto gil on/off
//counter auto all on/off
```

### Per-category shortcuts
```
//counter gil                          Show gil total (also: reset / clear)
//counter use                          Show usable items (also: clear / list)
//counter ammo                         Show currently equipped ammo
//counter drop                         Show Item Drops (also: reset / clear / list)
//counter personal                     Show Personal Drops (also: reset / clear / list)
//counter key                          Show key items (also: clear / list)
```

### Sets
```
//counter addset <name>                Save your current tracking as a named set
//counter set <name>                   Load a set
//counter listsets                     List all saved sets
//counter deleteset <name>             Delete a set
```

### Session, Focus, and Quiet mode
```
//counter focus <item name>            Pin an item to keep an eye on
//counter unfocus                      Clear the pinned item
//counter quiet                        Toggle quiet mode
```

### Chat log filtering

Common channels (Say, Shout, Yell, Tell, Party, Linkshell, Emote, System,
Unity) are shown by default. To adjust which channels appear:
```
//mogwatch chatmode <N> on/off         Add/remove a chat mode from the relay
//mogwatch chatname <N> <label>        Give a chat mode a readable label
//mogwatch chatname <N> clear          Remove a label
```

### Display
```
//mogwatch buffinfo <id>               Diagnostic: dump known fields for a buff/debuff ID
```

### Debugging (only needed if something's not working)
```
//counter debug                        Toggle debug mode for drop detection
//counter debugall                     Show every incoming chat line (very spammy — use briefly)
//counter test <item name>             Simulate a drop, for testing
//counter testpersonal <item name>     Simulate a personal drop (testobtain works too, same thing)
//counter testgil <amount>             Simulate a gil gain
//mogwatch chatdebug                   Toggle a hex dump of chat lines
//mogwatch buffdebug                   Toggle buff-timer diagnostic prints
//mogwatch commanddebug                Toggle detailed logging of viewer→game commands
//mogwatch commandtest                 Force a fresh connection test between addon and viewer
```

---

## Troubleshooting

**Nothing shows up in the viewer at all**
- Confirm the addon actually loaded: you should see a "loaded
  successfully" message in the FFXI chat log after `//lua load mogwatch`.
- Confirm the viewer is actually running and its status line at the
  bottom doesn't show an error.
- If you changed the port or host with `//mogwatch host`/`port`, make
  sure the viewer was started with the matching `--port` argument.

**Counter tab buttons say "not connected to game"**
- Run `//mogwatch commandtest` in-game. It'll report exactly what's
  wrong, or confirm the connection is fine — if it says "connected
  successfully" but buttons still don't work, turn on
  `//mogwatch commanddebug` and try again to see exactly what's
  happening.

**An item won't remove / says it's not tracked**
- Double-check the exact name shown in the Counter tab matches what
  you're trying to remove — special characters or unusual formatting in
  an item's name can occasionally cause a mismatch. Turning on
  `//mogwatch commanddebug` before trying again will show exactly what
  text the addon received.

**Maps don't show the right image**
- Open the Map window itself — it prints the exact filename it's
  looking for based on your current zone, which makes it easy to spot a
  naming mismatch.

**A drop wasn't tracked automatically**
- Item Drops auto-tracking is off by default. Either turn it on
  (`//counter auto drop on`) or add the specific item you want tracked.
  Personal Drops, Usable Items, and Gil are all on by default.
