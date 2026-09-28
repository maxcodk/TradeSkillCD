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

### Optional: syncing between accounts

If you play several characters spread across *different* WoW accounts
(not just different characters on one account) and want to see all of
their cooldowns from any of them, install **SuperWoW**:

- https://github.com/balakethelock/SuperWoW

Just having SuperWoW installed and running is enough — TradeSkillCD
detects it automatically and starts syncing. Nothing needs to be
configured in TradeSkillCD itself for this to work.

Without SuperWoW, the addon still works perfectly fine — it just keeps
track of cooldowns for the characters on the account you're currently
using, which is normal Blizzard-style addon behavior.

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
| `/tscd sync` | Forces an immediate sync with other accounts (requires SuperWoW) |
| `/tscd chat` | Turns chat notifications on/off |
| `/tscd rw` | Turns the on-screen (raid-warning style) "ready" notification on/off |
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
- a centered on-screen message (if `rw` notifications are on),
- a "level up" sound (if `sound` notifications are on).

## Look & feel

Chat output is deliberately neutral: soft white and grey text, with a
muted green for "ready" and a muted red for "off"/errors. 

`/tscd status` lists each character on its own line with their
professions indented underneath, the current character first, then the
rest of the current realm, then other realms.

## Troubleshooting

- **"SuperWoW not detected"** — this just means cross-account syncing is
  off; everything else still works normally for the account you're on.
- **Nothing shows up in `/tscd status`** — run `/tscd scan` once so the
  addon can do its first check, and make sure you've actually learned
  Alchemy, Tailoring, or Leatherworking on that character.
- **Cooldown looks wrong after using a Salt Shaker** — wait a couple of
  seconds after using it (it's picked up automatically), or run
  `/tscd scan` to force an immediate check.
- **No cooldowns in the pfUI clock tooltip** — make sure the clock is
  shown in one of pfUI's panels. If the hook fails, a red
  `pfUI tooltip hook failed: ...` line appears in chat with the reason.
- **Something seems broken / an error shows in chat** — the main event
  handler runs inside a safety wrapper, so a problem prints a red
  `error handling <EVENT>: ...` message with the exact reason instead
  of silently breaking. If you see one, that text is the actual cause —
  worth reporting so it can be fixed.
