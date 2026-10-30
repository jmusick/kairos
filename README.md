# Kairos

A rotation helper for World of Warcraft Retail (Midnight, 12.x). Kairos shows what to press next. It **recommends and never acts**: it sends no input to the game, in any build (SPEC D1).

The design, decisions and roadmap are in [SPEC.md](SPEC.md).

## Status: 0.1.0

0.1.0 is the foundation plus the secrecy probe. It doesn't run SimC APLs yet, so every spec shows Blizzard's Assisted Combat pick with the **AC** badge (D17, D33).

What works:

- **Display:** a main icon, a queued icon, and an interrupt icon, with keybind text, the AC badge and a CD pip. It's always visible, movable, scalable and lockable. The queued and interrupt icons stay hidden until a Kairos APL supplies them, since Assisted Combat gives one spell.
- **Keybinds:** default action bar slots (with paging and bonus bars), macros resolved to their spell, and per-spec manual overrides.
- **Cooldowns toggle:** a keybind (Key Bindings > AddOns > Kairos) and `/kairos cd`. It has no effect until a Kairos APL runs, because Assisted Combat ignores it.
- **Secrecy probe:** records which reads come back secret in the current context and renders a copyable Markdown matrix (SPEC §8.1).
- **Flight recorder:** logs pick changes and your casts to `KairosDB` for the future replay harness.
- **Settings:** a native Settings panel (Options > AddOns > Kairos) and per-character, per-spec profiles.

## Install for development

The addon lives in `Kairos/`. Junction it into the game's AddOns folder so `/reload` picks up edits:

```powershell
New-Item -ItemType Junction -Path 'C:\Games\World of Warcraft\_retail_\Interface\AddOns\Kairos' -Target 'C:\Users\JD\source\kairos\Kairos'
```

Turn on `/console scriptErrors 1` (or use BugSack) while testing.

## Commands

| Command | What it does |
|---|---|
| `/kairos` or `/kai` | Help |
| `/kairos lock`, `unlock`, `reset`, `scale <0.5-2>` | Display position and size |
| `/kairos cd [on\|off]` | Flip or set the Cooldowns toggle |
| `/kairos bind <spell> <text>`, `unbind <spell>`, `binds` | Keybind text overrides (spell name or ID) |
| `/kairos why` | Why the current pick was chosen |
| `/kairos status` | Version, spec, profile, APL, restrictions |
| `/kairos probe [label]` | Run the secrecy probe now |
| `/kairos probe report [n]` | Copyable Markdown matrix of the last n runs (default 8) |
| `/kairos probe auto on\|off` | Probe on entering combat, encounters and keystones |
| `/kairos probe clear` | Delete stored probe runs |
| `/kairos recorder on\|off\|clear` | Flight recorder |
| `/kairos config` | Open the settings panel |

## Running the probe (the first real task)

The probe answers the questions that decide the fallback gate (SPEC §10.1): whether Arcane Charges, Arcane Salvo stacks, Arcane Soul and cooldowns are readable in combat. To collect a full matrix on 12.1.x:

1. Out of combat in the open world: `/kairos probe world-ooc`.
2. In open-world combat (on a training dummy works): `/kairos probe world-combat`.
3. Turn on `/kairos probe auto on`, then run a dungeon (M+ if possible) and a raid boss.
4. `/kairos probe report`, copy the matrix, and commit it under `docs/probe/` with the client build in the file name.

## Tests

Specs are in `tests/` and run under busted (Lua 5.1) with a WoW API stub that can return secret values:

```bash
busted
```

Without busted, the bundled runner runs the same specs on any Lua 5.1+ interpreter, including the one inside the LuaLS VS Code extension:

```bash
~/.vscode/extensions/sumneko.lua-3.19.2-win32-x64/server/bin/lua-language-server.exe tests/run.lua
```

## Files

| File | Purpose |
|---|---|
| `Kairos/Kairos.toc` | Load order, version, SavedVariables |
| `Kairos/Bindings.xml` | The Cooldowns toggle keybind |
| `Kairos/Core.lua` | Namespace, module registry, event bus |
| `Kairos/Signal.lua` | Secret-safe reads (known, estimated, unknown) and restriction tracking |
| `Kairos/DB.lua` | `KairosDB` defaults and per-character, per-spec profiles |
| `Kairos/State.lua` | Own casts, cast in progress, combat, movement, enemy nameplates |
| `Kairos/Keybinds.lua` | Slot-to-key map, macro resolution, overrides |
| `Kairos/Toggles.lua` | The Cooldowns toggle |
| `Kairos/Assisted.lua` | Blizzard's Assisted Combat (the fallback floor) |
| `Kairos/APL.lua` | APL runtime shell and module contract |
| `Kairos/Recorder.lua` | Flight recorder |
| `Kairos/Display.lua` | The icons |
| `Kairos/Probe.lua` | Secrecy probe and report |
| `Kairos/Settings.lua` | Settings panel |
| `Kairos/Commands.lua` | Slash commands and the copy-text window |
| `tests/` | Specs, the WoW API stub, and the fallback runner |
