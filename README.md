# MogWatch - README

## What this is

A Windower 4 addon with two halves:

1. **A bridge** that sends live player/party status to the MogWatch desktop companion app over a small binary UDP/TCP protocol (position, vitals, buffs, party member status), and can receive chat/macro text typed into the app and enter it in-game.

2. **Counter** - an item drop, gil, and usable-item tracker, originally a standalone addon, now merged directly into this file. Tracks drops, personal items, key items, and gil; supports saved gear/tracking "sets"; and drives an in-game overlay popup (LootPopup, a separate addon) whenever something is obtained.

Counter works completely on its own even if you never set up the companion app or LootPopup - the two halves are independent.

## Install

Put this file in your `Windower4/addons/mogwatch/` folder as `mogwatch.lua`, then in game:

```
//lua load mogwatch
```

Per-character settings (tracked items, sets, gil totals, etc.) are saved automatically and reloaded next time you log in on that character.

## Bridge / companion app commands

| Command | Description |
|---|---|
| `//mogwatch` | show current bridge target/state |
| `//mogwatch host <address>` | set the app's IP (loopback needs no pairing) |
| `//mogwatch port <number>` | set the bridge port (must match the app) |
| `//mogwatch pair <code>` | pair using the code shown in the app |
| `//mogwatch unpair` | clear pairing |
| `//mogwatch chatdebug` | toggle a hex dump of captured chat lines to the console (for diagnosing garbled text) |
| `//mogwatch buffdebug` | toggle console logging of raw buff-timer packet values (only useful if a timer looks wrong) |
| `//mogwatch chatmode <N> on\|off` | show/hide a chat mode number in the relay to the app |
| `//mogwatch chatmode` | list currently shown chat modes |
| `//mogwatch chatname <N> <label>` | label a chat mode with its real channel name (e.g. "Linkshell") once you've identified it |
| `//mogwatch chatname` | list currently assigned chat mode labels |
| `//mogwatch buffinfo <id>` | dump all real fields of a `res.buffs` entry (e.g. `buffinfo 2` for Poison) - for fixing buff/debuff classification |
| `//mogwatch commandtest` | force a fresh command-channel connect attempt with guaranteed console output |
| `//mogwatch commanddebug` | toggle detailed logging of receiving/executing a command sent from the app |

**Current status:** pairing/encryption handshake, the binary status protocol, player vitals/position/buffs, party member vitals, and receiving chat/macro text from the app all work. Target frame, cast bar, npc/map layer, macro book display + remote execution, in-game chat log relay, exp tracking, and ctrl+arrow subtarget paging are **not built yet**.

## Counter commands

*(also usable as `//cnt` instead of `//counter`)*

### Tracking

| Command | Description |
|---|---|
| `//counter add <item name>` | add an item to tracking (auto-categorized) |
| `//counter add ItemA, ItemB, ItemC` | add multiple items at once |
| `//counter remove <item name>` | remove an item from tracking |
| `//counter list` | list all tracked items in chat |
| `//counter clear` | clear all lists |
| `//counter reset` | reset all counters to 0 |
| `//counter reset <item name>` | reset one item's counter to 0 |
| `//counter resetitem <item name>` | same as above |

### Auto-add toggles

| Command | Description |
|---|---|
| `//counter auto` | show auto-add status for all categories |
| `//counter auto drop on\|off` | toggle auto-add for drops |
| `//counter auto usable on\|off` | toggle auto-add for usable items |
| `//counter auto gil on\|off` | toggle auto-add for gil |
| `//counter auto personal on\|off` | toggle auto-add for personal drops |
| `//counter auto all on\|off` | toggle auto-add for every category |

### Categories

| Command | Description |
|---|---|
| `//counter gil` | show gil total |
| `//counter gil reset` / `clear` | reset/clear gil |
| `//counter use` | show usable items |
| `//counter use clear` / `list` | manage usable items |
| `//counter ammo` | show equipped ammo |
| `//counter drop` | show dropped items |
| `//counter drop reset` / `clear` / `list` | manage dropped items |
| `//counter personal` | show personal drops |
| `//counter personal reset` / `clear` / `list` | manage personal drops |
| `//counter key` | show key items |
| `//counter key clear` / `list` | manage key items |

### Sets

| Command | Description |
|---|---|
| `//counter addset <name>` | save current drops/personal/usable as a named set |
| `//counter set <name>` | load a set (replaces drops, merges personal/usable) |
| `//counter listsets` | list all saved sets |
| `//counter deleteset <name>` | delete a saved set |

### Misc

| Command | Description |
|---|---|
| `//counter quiet` | toggle quiet mode (suppresses automatic drop chat spam) |
| `//counter focus <item name>` | pin an item at the top of the display |
| `//counter unfocus` | clear the focused item |
| `//counter export` | write a summary to a text file in the addon's data folder |

### Debugging

| Command | Description |
|---|---|
| `//counter debug` | toggle debug mode (prints details for obtain messages) |
| `//counter debugall` | print the mode number + raw text of **every** chat line (very spammy - use to find a drop message format that isn't being detected, then turn back off) |
| `//counter test <item name>` | manually increment a counter |
| `//counter testpersonal <item name>` | test a personal drop |
| `//counter testgil <amount>` | test a gil addition |

### Display

| Command | Description |
|---|---|
| `//counter show` / `hide` | show/hide the display window |
| `//counter help` | print this command list in-game |

**Notes:**
- Usable items appear in magenta, ammo in yellow, key items in blue.
- Items are sorted alphabetically within each category.
- Ammo is tracked automatically when equipped.
- Steal and Mug actions are tracked automatically.
- Click any toggle row to flip it, or click an item for an action menu.
- Right-click an item to remove it instantly, skipping the menu.

## LootPopup integration

Counter automatically triggers the separate LootPopup addon (an in-game fading toast overlay) whenever it detects a drop, across several different message formats:

- Enemy loot (`"<Player> obtains <item>."`)
- Personal drops (`"You obtain (x) <item>."`)
- Chest/NPC drops (`"Obtained: <item>"`)
- A second personal-drop message channel (mode 121 - same phrasing as enemy loot but correctly routed to the Personal tab, not Drops)
- Temporary-item personal drops (`"obtains the temporary item: <item>"`)

This happens via `windower.send_command('lootpopup show <id> <name>')` - LootPopup is a fully separate addon and needs to be installed and loaded on its own (see its own README) for popups to actually appear; Counter's tracking works fine on its own either way.

If a drop type is ever silently missed by both Counter and LootPopup, `//counter debugall` on that drop is the fastest way to find out why - it'll show the exact chat mode number and raw message text, which is what's needed to add support for a new format.
