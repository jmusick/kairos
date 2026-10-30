# Kairos

A rotation helper for World of Warcraft Retail (Midnight, 12.x). Kairos shows what to press next. It **recommends and never acts**: it sends no input to the game, in any build (SPEC D1).

The design, decisions and roadmap are in [SPEC.md](SPEC.md).

## Status: 0.2.0

The checkout runs generated Arcane Sunfury and experimental Demonology APLs through in-game state adapters. Both still need live validation. Demonology supports Diabolist and learned-spell gating for leveling (including the user's level 80 build). Unknown inputs and unsupported specs/Spellslinger show Blizzard's Assisted Combat pick with the **AC** badge (D17, D33).

What works:

- **Display:** a main icon with keybind text, the AC badge and a CD pip. It's visible regardless of combat, movable, scalable and lockable, with an enable/disable control. Arcane's Barrage gains a smaller blue-bordered Touch icon overlapping its upper-right corner when the APL calls for Barrage immediately followed by Touch, matching the user's macro. Touch ready now takes the main icon with a **NOW** badge. Ordinary queues stay hidden until future proc changes can be modeled; Touch can show its on-GCD follow-up. Interrupt recommendations are not wired yet.
- **Keybinds:** default action bar slots (with paging and bonus bars), macros resolved to their spell, and per-spec manual overrides.
- **Cooldowns toggle:** a keybind (Key Bindings > AddOns > Kairos) and `/kairos cd`. Holds Arcane Surge/Touch and Demo's Tyrant, Grimoires and Doomguard as just used (D15). Dreadstalkers and Power Siphon remain rotational. Assisted Combat ignores the toggle when Kairos falls back.
- **Secrecy probe:** records which reads come back secret in the current context, automatically (SPEC §8.1).
- **Flight recorder and fight traces:** pick changes, casts, charges, glows and aura events, saved to `KairosDB` for offline analysis.
- **Combat logging:** turned on automatically, with advanced logging, and checked again at pull/encounter start in case another logging manager stopped it between pulls.
- **Settings:** a native Settings panel (Options > AddOns > Kairos) and per-character, per-spec profiles. Main icon size has a slider and numeric edit box (32–128, default 52 × 52 before overall display scale); the overlapping Touch icon stays half its size.

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
| `/kairos position <x> <y>` or `pos <x> <y>` | Main icon offset from screen center; right/up positive. Settings also has sliders and numeric edit boxes. |
| `/kairos enable`, `disable` | Resume or suspend display/recommendations account-wide; passive state tracking continues. |
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

`salvo` scores the Arcane Salvo estimator against the log's true stacks. `apl` compares, at every decision, the Arcane APL on true state, the APL with Kairos's Salvo and Cumulative Power estimates, Assisted Combat's pick and the player's cast, grouped by APL line. When the recorder contains `src = "kairos"` picks, it also reports **Kairos in game = APL on true state**, per-line agreement, displayed agreement including AC fallback, and the fallback share. Both live sources use the same cast-success clock alignment and the last recommendation before each decision. Matched cast order prevents a post-cast recommendation from being graded against its own cast when timestamps share a frame. Barrage's newly generated Bolt proc is excluded from its pre-press state, then retained for subsequent decisions. `watch` checks whether any field of the recorder's spell-watch signatures tracks a hidden aura from the log.

### Live Arcane state and limits

`ArcaneState` builds the generated APL contract at the later of the current cast/channel end and the GCD end (D29). It reads charges and the Missiles/Bolt glows through Signal; Clearcasting is presence only (0 or 1). It projects active Missiles through the existing Salvo and Cumulative Power estimators, and applies Blast/Bolt gains and consumption or Surge's buff when a cast is still in progress. Projection never changes the live estimators. New random procs and extra charge gains during that interval are not predicted.

- Touch (45 s), Surge (90 s), Orb (two charges, sequential 20 s recharge) and the Mage's Pulse (`1241462`, 15 s) are timed from own casts and corrected out of combat. Pulse is distinct from the Nightborne racial (`260364`). In-combat reductions/resets are not modeled. Surge lasts 17.4 s; Soul uses Salvo's timed window and glow correction.
- Surge waits for Touch to be learned and ready at cast/GCD end, so a delayed mini-burst cannot cause Kairos to recommend a desynchronized Surge (D37). This user-requested availability constraint is in translator metadata; it preserves the actual cooldown values. While waiting, the APL continues selecting rotational spells.
- After a manual Orb, a 1.5 s pending-flight guard advances the main icon instead of immediately recommending its second charge while the first Orb's gains arrive. Barrage clears the guard after a new spend; otherwise it expires automatically, including if Orb hits nothing. The model keeps using the readable Arcane Charge count. This is a bounded flight estimate; distance and impacts are not read live.
- While Bolt is casting, lookahead consumes its proc in the predicted state. Kairos draws the original icon of its exact recommendation, so a following Blast appears as Blast even while the live action button still shows Bolt. Cast/channel events refresh the display immediately; interruption restores the recommendation from current state.
- Haste/GCD length, talent and spell knowledge, and Lustrous Gleam (`1295147`) stacks are cached out of combat. The S2 four-piece is checked against equipped set 2060; a false spellbook query does not prove an item-set passive absent. Missing item data remains unknown until it loads. Haste buffs and Gleam changes during combat can make their estimates stale. Bolt inherits Blast's knowledge because it temporarily replaces it.
- Enemy count includes every hostile nameplate, including dummies that report no combat. It has no range filter or hysteresis yet. Secret hostility makes the count unknown.
- Uncertainty is conservative: an unknown read anywhere on the evaluated priority path, including a rejected higher-priority rule, forces AC. Estimates count as known. Unknown inputs use placeholders behind a read-tracking proxy; those values never authorize a displayed guess. `/kairos why` and recorded picks name the fields that caused fallback. Unknown cast/GCD timing forces AC for the main pick; the immediate off-GCD cue is independent of that timing.
- While moving, stationary actions are filtered out before evaluating priorities, allowing Barrage/Orb; Clearcasting Missiles is allowed with learned Slipstream. Unknown movement falls back to AC when the pick needs stationary casting. Pulse's Salvo gain is not modeled: after casting it, Salvo remains unknown until a consuming Barrage or a readable aura re-anchors it. Spellslinger, translated precombat buff upkeep and other omissions in the [translator coverage](translator/README.md#coverage-and-remaining-work) remain unsupported. One-step queued recommendations remain hidden.
- Touch ready now uses current state and takes the main icon, so it does not fire before a Bolt trigger lands. For a Barrage/Touch pair, the overlapping Touch icon previews the immediate off-GCD follow-up at Barrage's evaluation boundary. It appears only if the generated Touch rule is satisfied and known, respects the Cooldowns toggle, and is independent of the queued-icon setting. The recorder includes the paired spell/label and `/kairos why` explains it. Salvo carries between fights: a 25-Salvo pull can start Surge → Barrage + Touch rather than building stacks with Missiles.

For the first score, `/reload` to load the adapter, keep enemy nameplates on and Cooldowns on, fight a dummy for a few minutes, note the start/end times, then `/reload` again to write SavedVariables. Run `apl` with that new log, SavedVariables, `Merlinmonroe`, and the two `HH:MM:SS` bounds. Use a CD-on, stationary Sunfury session for the baseline: the current true-state replay does not apply the live toggle or movement policy. The two-estimator score remains a separate diagnostic, not the live agreement result.

### Demonology leveling and Diabolist

Switch to Demonology and `/reload` to load the module. It reads your actual learned spells and talent choices out of combat and refreshes them as you learn/change talents. No talent import is needed. Diabolist uses the pinned SimC `diabolist` list; before hero talents unlock, the generated `Leveling()` entry uses the shared `soulharvest` priorities. Soul Harvester also has a generated route, but Diabolist is the initial play-test target. A missing/dead pet outside combat recommends a learned Summon Felguard or Summon Imp. Kairos only recommends; you cast it yourself.

The module reads Soul Shards through Signal, checks proc replacements before recommending Infernal Bolt or Ruination, and projects deterministic shard gains/costs to cast/GCD end. Ruination is free. Movement filters cast-time spells out of the priority list while allowing proc-instant Demonbolt, Siphon, Implosion and other instants. Cooldowns, own casts, shard changes, glows and spell-watch signatures are recorded automatically.

This is an **unscored prototype**, with these limits:

- Demonic Core's readable aura count is used when available. When hidden, the Demonbolt glow supplies presence only. A count-sensitive decision is accepted only if every possible 1–4 stack value returns the same spell; otherwise the AC badge appears. A `[core stack independent]` label marks a spell shared by different possible priority lines.
- Wild Imps are estimated from Hand (three) and Ruination (three after about 0.4 s), consumed by Siphon/Implosion, and aged by five hasted 2 s Firebolts. Movement, target downtime, extra imp talents/procs and changing haste can make that count wrong. It has not been calibrated against your Warlock's logs.
- Base cooldowns are Implosion 15 s, Dreadstalkers 20 s, Siphon 30 s, Tyrant 60 s, and Grimoires/Doomguard 120 s, corrected out of combat. Implosion remains rotational when the Cooldowns toggle is off. The Doomguard model subtracts 3 s for a Demonbolt whose Core presence was observed. Dominion of Argus, if learned later, is timed for 15 s from Tyrant and refreshed by Hand/Ruination. Haste is cached out of combat. New random procs are not predicted at cast end.
- Fight remains is a long-fight estimate (300 s); end-of-fight dumps, target selection for Doom, items, racials and most precombat setup are omitted. The queue is hidden. Unknown shards/procs/timing or talent reads that can affect the priority path use AC.

For the first Demo check, play several pulls or a 3-minute dummy fight, then `/reload` so SavedVariables reaches disk. Auto-probes and the recorder collect the inputs; no manual probe command is needed. `probes`, `events`, and `fights` can inspect that data offline. **The `apl` scorer is still Arcane-only**, so there is no Demonology agreement percentage yet. Arcane remains the global fallback gate (D6).

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
| `Data/Trace.lua` | Fight traces: spec resources (charges/shards), glows, aura events, stacks before and after each fight |
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
| `Specs/MageArcane/APL.lua` | Sunfury APL, generated by `translator/` (don't edit); loaded before the live adapter |
| `Specs/MageArcane/State.lua` | `ArcaneState`: live state contract, cast-boundary prediction, cached context/cooldown models, uncertainty tracking and spec 62 registration |
| **`Kairos/Specs/WarlockDemonology/`** | **Demonology Warlock only** |
| `Specs/WarlockDemonology/Spec.lua` | Spell/aura IDs, traced Soul Shards and the Demo secrecy probe/watch lists |
| `Specs/WarlockDemonology/Demons.lua` | `DemonologyDemons`: own-cast Wild Imp estimate with explicit times for future offline replay |
| `Specs/WarlockDemonology/APL.lua` | Generated Diabolist/Soul Harvester priorities and a shared leveling entry (don't edit) |
| `Specs/WarlockDemonology/State.lua` | `DemonologyState`: learned spells/talents, resources/procs, cooldown and cast-boundary models, movement and uncertainty; registers spec 266 |
| `tests/` | Specs, the WoW API stub, and the fallback runner |
| `translator/` | Offline C# SimC APL translator (partial: Arcane Sunfury and cooldowns), with golden, coverage and parity tests |
| `tools/kairos-dump.lua` | Reads SavedVariables and combat logs offline, and replays logs through the Arcane modules |
| `docs/probe/` | Probe and estimator results per client build, with findings |
| `docs/replay/` | APL replays: Kairos, Assisted Combat and the player against the APL on true state |
