# AGENTS.md

Guidance for AI coding agents working in this repository.

## Read first

[SPEC.md](SPEC.md) is the source of truth for scope and design. Its decision log (D1–D33) records settled choices. Don't reopen one without the user; if a change would contradict one, stop and ask.

Hard lines from the spec, which no change may cross:

- **Never send input to the game** (D1, N1). No keystrokes, mouse or controller events, no "press for me" mode, and no hooks that would make one trivial to add. Kairos never calls protected functions or uses secure action buttons.
- **No memory reading, injection or client modification** (N2), and **no evasion features** (N3).
- **The combat log is never read live** (D9). It's an offline test input only.

## Stack

- Pure Lua 5.1 **WoW Retail addon** for Midnight (12.x), with **no library dependencies** (no Ace3, no LibStub) (D27). The game loads the files listed in `Kairos/Kairos.toc`, in order, straight from the `Kairos/` folder. There's no build step.
- Persistence is one account-wide SavedVariable, `KairosDB`: `global` settings, `profiles[charKey][specID]`, `flight` (recorder) and `probes`. It reaches disk only on logout or `/reload`.
- Planned but not built yet: the C# SimC translator, generated APL modules, and the C# replay harness (SPEC §8). Generated Lua will be committed and never hand-edited (D21).

## Conventions

- **Layout:** `Kairos/Core/` (namespace, Signal, DB), `Engine/` (spec-agnostic runtime: State, Keybinds, Toggles, Assisted, APL), `Data/` (Recorder, Trace, CombatLog, Probe), `UI/` (Display, Settings, Commands), and `Specs/<Class><Spec>/` for anything that applies to one specialization. Generic code never names a spec's spells or auras.
- **Specs:** each spec folder has a `Spec.lua` that calls `Kairos:NewSpec(specID, { key, name, probe = {...}, auraIDs = {...} })`; generic modules (Probe, Trace) read the active spec through `Kairos:CurrentSpec()`. Spec state models (`Specs/MageArcane/Salvo.lua`, `CumulativePower.lua`) are modules named with the spec prefix (`ArcaneSalvo`, `ArcaneCumulativePower`), take explicit times in every method so the replay can drive them, and stay inert on other specs. A spec's APL lives in the same folder (`APL.lua`).
- **Module pattern:** each file opens with `local _, Kairos = ...` and registers with `local X = Kairos:NewModule("X")`, which also sets `Kairos.X`. Modules may define `OnInit` (SavedVariables ready) and `OnLogin` (character and spec known). Core calls them in TOC order, so a module may use modules listed above it at file scope, and any module at runtime.
- **Events:** use `Kairos:On(event, fn)` for client events and `Kairos:Fire`/`Kairos:On` with a `KAIROS_` prefix for internal messages (`KAIROS_PROFILE_CHANGED`, `KAIROS_TOGGLE_CHANGED`, `KAIROS_PLAYER_CAST`, `KAIROS_COMBAT_CHANGED`, `KAIROS_RESTRICTIONS_CHANGED`). For unit events use `Kairos:OnUnit(event, unit, fn)`, which filters in the client. Never compare a unit token from a payload in Lua: it can be secret.
- **Secret values:** every read of combat state goes through `Kairos.Signal` (`Read`, `ReadField`), which returns `{ state = "known"|"estimated"|"unknown", value, reason }` and never throws. Don't compare, do arithmetic on, index, `#`, concatenate or `tostring` a value without checking it with `issecretvalue` first. Secrets may be passed to widgets that accept them; logic may not branch on them.
- **Secret auras read as `nil`, not secret.** `C_UnitAuras.GetAuraDataBySpellName` and `GetPlayerAuraBySpellID` are `RequiresNonSecretAura`: in combat they return `nil` for an aura that is up but secret. Check `C_Secrets.ShouldSpellAuraBeSecret(id)` before treating `nil` as "aura down". Probe results per client build live in `docs/probe/`; check them before assuming any read works in combat.
- **Uncertainty (D17, G3):** when the main pick depends on unknown state, show Assisted Combat's pick with the AC badge. When only the queued pick does, hide the queued icon. Never show a blank or dimmed guess.
- **Defaults:** `DB.lua` holds every default (`globalDefaults`, `profileDefaults`). New settings go there, not ad hoc in a module. Read per-spec settings through `Kairos.profile`, which is replaced on spec change, so never cache it in a local.
- **APIs:** prefer `C_*` namespaces, falling back to legacy globals where an API moved. Guard anything that may not exist (`C_X and C_X.Fn`). Check names against Blizzard's generated docs ([wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/live/Interface/AddOns/Blizzard_APIDocumentationGenerated)) or Ketho's annotations rather than memory, since Midnight renamed and restricted many.
- **New files** go into `Kairos/Kairos.toc` in dependency order, the README file table, and get a spec in `tests/`.
- **Tests:** specs use only the busted subset `tests/run.lua` implements (`describe`, `it`, `before_each`, `assert.are.equal/same`, `assert.is_true/is_false/is_nil/is_not_nil`, `assert.truthy/falsy`, `assert.matches`, `assert.has_error/has_no_error`). Add to the runner if a spec needs more. `tests/wow_stub.lua` resets every global the addon reads; when the addon starts calling a new API, stub it there. Use `Stub.Secret()` to test secret handling.

## Commands

- Tests: `busted` from the repo root (Lua 5.1). Without busted: `lua tests/run.lua`, or run `tests/run.lua` with the `lua-language-server.exe` bundled in the LuaLS VS Code extension, which works as a Lua interpreter.
- Lint: `luacheck .` (config in `.luacheckrc`). Type and API checks: LuaLS with Ketho's WoW API annotations (`.luarc.json`; the VS Code extension adds the annotations).
- In game: the `Kairos/` folder is junctioned into `C:\Games\World of Warcraft\_retail_\Interface\AddOns\Kairos`. `/reload` after edits, with `/console scriptErrors 1` on. `/kairos status` confirms it loaded.
- In-game data, read offline (the user doesn't need to run commands or paste reports):
  - SavedVariables: `C:\Games\World of Warcraft\_retail_\WTF\Account\ANGELUS35C\SavedVariables\Kairos.lua`, written on `/reload`, logout or exit. Check its timestamp; data from the current play session isn't there until one of those happens.
  - Combat logs: `C:\Games\World of Warcraft\_retail_\Logs\WoWCombatLog-*.txt`. Kairos turns logging on at login.
  - `tools/kairos-dump.lua` (`probes`, `fights`, `summary`, `events`, `combatlog`, `salvo`, `apl`) reads both. Run it with the LuaLS binary if there's no `lua` on PATH.
  - `salvo` replays a log through `Specs/MageArcane/Salvo.lua` and scores it; rerun it on every new log before and after changing `Salvo.GAINS`, and don't tune on the log you report as validation.
  - `apl` compares the APL on the log's true state with Kairos (the APL on the Salvo and Cumulative Power estimates, each also shown alone), Assisted Combat (from the recorder) and the player's casts, per APL line. Decisions are cast starts for cast-time spells and successes otherwise; the recorder is aligned to cast successes.
  - To compare a trace with a combat log, align them by matching casts (recorder `t` is `GetTime()`; `at` has only one-second resolution). A Blast or Prismatic Bolt success and the next queued spell land milliseconds apart; both are real presses.
  - Open-world training dummies drop combat within seconds of a pause, even mid-channel, so one dummy session shows up as many short fights.
- Packaging: BigWigs packager with `.pkgmeta` (`Kairos/Kairos` moves to the package root). No CI yet (D23).

## Releases

The version lives in `## Version` in `Kairos/Kairos.toc` and in `CHANGELOG.md` (Keep a Changelog format, newest first, with an Unreleased section). Bump both together. Update `## Interface` when Blizzard ships a new client build.

## Notes

- A spec's `probe` table (in its `Spec.lua`) lists spells, auras and powers **by name**, because several Midnight spells are new and their IDs aren't confirmed. Aura names must match the aura, not the spell: the Prismatic Bolt proc is "Prismatic Bolt!" (`1295942`). Put confirmed IDs in `auraIDs`.
- `Specs/MageArcane/APL.lua` is hand-written from SimC `515f4a3fe9` as a stopgap (D21 says APL Lua is generated). It isn't in the TOC because the in-game state doesn't provide its fields yet. When the translator exists, its output replaces this file, and `tests/arcane_apl_spec.lua` plus the replay logs become golden tests.
- The Keybinds map keeps its last full build if a rebuild hits secret reads in combat, and retries at most once a second. Don't make it rebuild every frame.
- The display refreshes on a throttled `OnUpdate` (`KairosDB.global.updateInterval`, 0.1 s by default) plus a few events. Keep per-refresh work small: SPEC §7.3 targets under 0.5 ms per evaluation.
