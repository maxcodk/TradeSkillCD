# TradeSkillCD

A World of Warcraft 1.12 (Turtle WoW / Octo WoW) addon that tracks
profession cooldowns for **Alchemy** (Arcanite Bar), **Tailoring**
(Mooncloth) and **Leatherworking** (Salt Shaker → Refined Deeprock Salt).
It remembers when each cooldown expires, tells you when something is
ready, and reminds you every time you log in.

Works fully on its own (no other addons required) through simple chat
commands. If you also have **SuperWoW** installed, it can additionally
share cooldown data between *different WoW accounts*, so you see every
character's status no matter which account you're logged into.

## Installation

1. Download/copy this whole `TradeSkillCD` folder into your addons
   directory:
   ```
   <your WoW folder>/Interface/AddOns/TradeSkillCD/
   ```
   Make sure the files (`TradeSkillCD.toc`, `TradeSkillCD.lua`,
   `README.md`) sit directly inside that `TradeSkillCD` folder, not in
   a subfolder.
2. Start the game, open the AddOns list on the character-select screen,
   and make sure **TradeSkillCD** is checked/enabled.
3. Log into a character. You'll see a short message in chat telling you
   whether cross-account syncing is active.

That's it — no configuration file to edit, no other addon needed.

### Optional: syncing between accounts/windows (HearthDB or SuperWoW)

TradeSkillCD works fine on its own. If you ever run **two game windows at
once** (two accounts, or two instances via a multiboxing tool) and want
both to see each other's cooldowns reliably, install one of these -
**HearthDB is the one to pick if you can**, for the reason below.

**HearthDB (recommended for multiboxing):**
https://github.com/copypasteonly/HearthDB

The normal addon save file (`SavedVariables`) is only written when you
log out, and each running window holds its own private copy in memory
from the moment it logged in - so with two windows open, whichever one
logs out *last* overwrites the file with a snapshot that can be missing
whatever the other window saved in the meantime. That's a limitation of
`SavedVariables` itself, not something an addon can work around.

HearthDB gives the addon a real shared database file instead
(`CustomData/TradeSkillCD.db`, shared by every account on this game
install, just like SuperWoW's shared file below). Every cooldown change
is written there the instant it happens, one small row at a time - so
two windows updating two different characters never overwrite each
other, and a window left open picks up what another window did within
about 20 seconds, no relog needed. If you had cooldowns tracked before
installing HearthDB, they're copied in automatically the first time it
loads.

**SuperWoW (fallback, used automatically if HearthDB isn't installed):**
https://github.com/balakethelock/SuperWoW

Just having HearthDB or SuperWoW installed and running is enough -
TradeSkillCD detects whichever one is available automatically (HearthDB
first, SuperWoW as a fallback) and starts syncing. Nothing needs to be
configured in TradeSkillCD itself. With neither installed, the addon
still works perfectly fine for a single account/window - it just can't
merge data between two windows open at the same time.

### Optional: pfUI

If you use pfUI, hover the **clock** in its panel: below the usual time
information, TradeSkillCD adds the cooldowns of **all** your known
characters (same data as `/tscd status`). This is purely a bonus — pfUI
is not required, and everything else works identically without it.

The clock has to be enabled in one of pfUI's panels (it is by default).
The tooltip hook is applied automatically a few seconds after login.

## How to use it

Everything is driven through chat commands:

| Command | What it does |
|---|---|
| `/tscd help` | Lists all available commands |
| `/tscd scan` | Manually checks your profession and tool cooldowns right now |
| `/tscd status` | Shows cooldowns for **every character** the addon knows about (all accounts, if SuperWoW sync is on) — current character first |
| `/tscd status me` | Shows cooldowns for the **current character** only |
| `/tscd sync` | Forces an immediate sync with other windows/accounts (HearthDB or SuperWoW) |
| `/tscd chat` | Turns chat notifications on/off |
| `/tscd sound` | Turns the "ready" sound on/off |

### When does it pick up cooldowns automatically?

- **Arcanite Bar / Mooncloth**: automatically, the moment you craft one —
  no need to run `/tscd scan` for these.
- **Truesilver Bar / Gold Bar**: these share their cooldown with Arcanite
  Bar, so crafting one of them makes the addon briefly re-open your
  profession window to read the real remaining cooldown, then close it
  again.
- **Salt Shaker**: also fully automatic. Any time your bags or bank
  change (after using it, looting, moving items around), the addon
  quietly checks the item's cooldown icon a couple of seconds later and
  records it — no manual scan needed. It only announces it once, the
  first time it notices a new cooldown; it won't spam you every time it
  re-checks the same ongoing cooldown.
- **General profession cooldowns**: running `/tscd scan` also briefly
  opens your Alchemy/Tailoring window to double-check for any active
  cooldown, in case something was missed.

### Getting reminded

Every few seconds the addon checks in the background whether any
tracked cooldown just expired. When one does, you'll get:

- a chat message (if `chat` notifications are on),
- a "level up" sound (if `sound` notifications are on, current character only).

This fires once, exactly when a cooldown finishes.

On top of that, a few seconds after every login the addon lists
everything that is currently ready, for **all** known characters (not
just the one you logged into) — so even a character without any
professions gets the reminder. It's a chat line only, no sound unless
the ready cooldown belongs to the character you're playing.

## Look & feel

Chat output is deliberately neutral: soft white and grey text, with a
muted green for "ready" and a muted red for "off"/errors. The pink
accent is used only for a few titles (help and status headers).

`/tscd status` lists each character on its own line with their
professions indented underneath, the current character first, then the
rest of the current realm, then other realms.

## Troubleshooting

- **"SuperWoW not detected" / no HearthDB message at login** — this just
  means cross-window/cross-account syncing is off; everything else
  still works normally for the account you're currently on.
- **Nothing shows up in `/tscd status`** — run `/tscd scan` once so the
  addon can do its first check, and make sure you've actually learned
  Alchemy, Tailoring, or Leatherworking on that character.
- **Cooldown looks wrong after using a Salt Shaker** — wait a couple of
  seconds after using it (it's picked up automatically), or run
  `/tscd scan` to force an immediate check.
- **The chat message at login seems missing** — it's delayed a few
  seconds on purpose so it doesn't get buried under every other addon's
  own login spam; check chat again a moment after logging in.
- **No "ready" notification when a cooldown finishes** — run
  `/tscd status` to confirm the cooldown really is the one that just
  hit zero (not one already marked ready earlier). The live
  notification fires once, at the exact moment a tracked cooldown
  reaches zero; the login reminder covers everything ready at login.
- **`HearthDB error (will keep retrying)` in chat** — the database
  refused access for a moment (this can happen when two windows touch
  it at the same time). Nothing is lost: failed writes are queued and
  retried, and the connection is re-established automatically. The
  message appears once per hiccup; if it keeps coming back, report it.
- **No cooldowns in the pfUI clock tooltip** — make sure the clock is
  shown in one of pfUI's panels. If the hook fails, a red
  `pfUI tooltip hook failed: ...` line appears in chat with the reason.
- **Something seems broken / an error shows in chat** — the main event
  handler runs inside a safety wrapper, so a problem prints a red
  `error handling <EVENT>: ...` message with the exact reason instead
  of silently breaking. If you see one, that text is the actual cause —
  worth reporting so it can be fixed.
