# Kairos

A rotation helper for World of Warcraft Retail (Midnight, 12.x). Kairos shows what to press next. It **recommends and never acts**: it sends no input to the game, in any build (SPEC D1).

The design, decisions and roadmap are in [SPEC.md](SPEC.md).

## Status: 0.1.0

0.1.0 is the foundation plus the secrecy probe. It doesn't run SimC APLs yet, so every spec shows Blizzard's Assisted Combat pick with the **AC** badge (D17, D33).

What works:

- **Display:** a main icon, a queued icon, and an interrupt icon, with keybind text, the AC badge and a CD pip. It's always visible, movable, scalable and lockable. The queued and interrupt icons stay hidden until a Kairos APL supplies them, since Assisted Combat gives one spell.
- **Keybinds:** default action bar slots (with paging and bonus bars), macros resolved to their spell, and per-spec manual overrides.
- **Cooldowns toggle:** a keybind (Key Bindings > AddOns > Kairos) and `/kairos cd`. It has no effect until a Kairos APL runs, because Assisted Combat ignores it.
- **Secrecy probe:** records which reads come back secret in the current context, automatically (SPEC §8.1).
- **Flight recorder and fight traces:** pick changes, casts, charges, glows and aura events, saved to `KairosDB` for offline analysis.
- **Combat logging:** turned on automatically, with advanced logging.
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
| `/kairos probe in <seconds> [label]` | Run the probe after a delay |
| `/kairos probe auto on\|off` | Automatic probes (on by default) |
| `/kairos probe clear` | Delete stored probe runs |
| `/kairos recorder on\|off\|clear` | Flight recorder |
| `/kairos config` | Open the settings panel |

## Collecting data (no commands needed)

Kairos collects what the fallback gate (SPEC §10.1) needs on its own:

- **Probes** run at login, 3 s into each fight, right after each fight, and at encounter and keystone starts (throttled to once a minute per kind).
- **Fight traces** go into the flight recorder: your casts, Arcane Charges, proc glows, in-combat aura events, and the real stacks of tracked auras (Arcane Salvo, Clearcasting, …) just before and after each fight.
- **Combat logging** is switched on (with advanced logging) at login, so every session leaves a `WoWCombatLog` file.

Just play, then `/reload` or log out so the game writes SavedVariables. The data lands in:

- `C:\Games\World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\Kairos.lua`
- `C:\Games\World of Warcraft\_retail_\Logs\WoWCombatLog-*.txt`

Read it with the dump tool (any Lua 5.1+ interpreter, including the LuaLS binary):

```bash
lua tools/kairos-dump.lua probes <Kairos.lua> [n]
```

```bash
lua tools/kairos-dump.lua fights <Kairos.lua> [n]
```

```bash
lua tools/kairos-dump.lua summary <Kairos.lua>
```

```bash
lua tools/kairos-dump.lua events <Kairos.lua>
```

```bash
lua tools/kairos-dump.lua combatlog <WoWCombatLog.txt> <Kairos.lua> [player]
```

```bash
lua tools/kairos-dump.lua salvo <WoWCombatLog.txt> <player> [from HH:MM:SS [to HH:MM:SS]] [verbose]
```

```bash
lua tools/kairos-dump.lua apl <WoWCombatLog.txt> <Kairos.lua> <player> [from HH:MM:SS [to HH:MM:SS]] [verbose]
```

```bash
lua tools/kairos-dump.lua watch <WoWCombatLog.txt> <Kairos.lua> <player> [auraID ...] [from HH:MM:SS [to HH:MM:SS]] [verbose]
```

`salvo` scores the Arcane Salvo estimator against the log's true stacks. `apl` compares, at every decision, the Arcane APL on true state, the APL with Kairos's Salvo and Cumulative Power estimates, Assisted Combat's pick and the player's cast, grouped by APL line. `watch` checks whether any field of the recorder's spell-watch signatures tracks a hidden aura from the log.

Results worth keeping go under `docs/probe/` (probe and estimator findings) and `docs/replay/` (APL replays), named by client build and context. Probes, auto-probing and combat logging can each be turned off in the settings panel.

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

The addon is split by what code is for. Anything that applies to one specialization lives under `Specs/`; everything else is spec-agnostic.

| File | Purpose |
|---|---|
| `Kairos/Kairos.toc` | Load order, version, SavedVariables |
| `Kairos/Bindings.xml` | The Cooldowns toggle keybind |
| **`Kairos/Core/`** | **Foundation** |
| `Core/Core.lua` | Namespace, module and spec registries, event bus |
| `Core/Signal.lua` | Secret-safe reads (known, estimated, unknown) and restriction tracking |
| `Core/DB.lua` | `KairosDB` defaults, migrations, per-character and per-spec profiles |
| **`Kairos/Engine/`** | **Spec-agnostic runtime** |
| `Engine/State.lua` | Own casts, cast in progress, combat, movement, enemy nameplates |
| `Engine/Keybinds.lua` | Slot-to-key map, macro resolution, overrides |
| `Engine/Toggles.lua` | The Cooldowns toggle |
| `Engine/Assisted.lua` | Blizzard's Assisted Combat (the fallback floor) |
| `Engine/APL.lua` | APL runtime shell and module contract |
| **`Kairos/Data/`** | **Collection and diagnostics** |
| `Data/Recorder.lua` | Flight recorder |
| `Data/Trace.lua` | Fight traces: charges, glows, aura events, stacks before and after each fight |
| `Data/CombatLog.lua` | Turns on advanced combat logging |
| `Data/Probe.lua` | Secrecy probe and report |
| **`Kairos/UI/`** | **Display and controls** |
| `UI/Display.lua` | The icons |
| `UI/Settings.lua` | Settings panel |
| `UI/Commands.lua` | Slash commands and the copy-text window |
| **`Kairos/Specs/MageArcane/`** | **Arcane Mage only** |
| `Specs/MageArcane/Spec.lua` | Metadata: aura IDs, and the spells, auras and powers to probe and trace |
| `Specs/MageArcane/Salvo.lua` | Arcane Salvo estimator: stacks in combat from casts and the Barrage glow |
| `Specs/MageArcane/CumulativePower.lua` | Cumulative Power (Season 2 4-piece) estimator: built by Missiles, consumed at 8 by Blast or Bolt |
| `Specs/MageArcane/APL.lua` | Sunfury APL, generated by `translator/` (don't edit; not in the TOC yet) |
| `tests/` | Specs, the WoW API stub, and the fallback runner |
| `translator/` | Offline C# SimC APL translator (partial: Arcane Sunfury and cooldowns), with golden, coverage and parity tests |
| `tools/kairos-dump.lua` | Reads SavedVariables and combat logs offline, and replays logs through the Arcane modules |
| `docs/probe/` | Probe and estimator results per client build, with findings |
| `docs/replay/` | APL replays: Kairos, Assisted Combat and the player against the APL on true state |
