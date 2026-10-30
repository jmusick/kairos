# AGENTS.md

Guidance for AI coding agents working in this repository.

## Read first

[SPEC.md](SPEC.md) is the source of truth for scope and design. Its decision log (D1–D38) records settled choices. Don't reopen one without the user; if a change would contradict one, stop and ask.

Hard lines from the spec, which no change may cross:

- **Never send input to the game** (D1, N1). No keystrokes, mouse or controller events, no "press for me" mode, and no hooks that would make one trivial to add. Kairos never calls protected functions or uses secure action buttons.
- **No memory reading, injection or client modification** (N2), and **no evasion features** (N3).
- **The combat log is never read live** (D9). It's an offline test input only.

## Stack

- Pure Lua 5.1 **WoW Retail addon** for Midnight (12.x), with **no library dependencies** (no Ace3, no LibStub) (D27). The game loads the files listed in `Kairos/Kairos.toc`, in order, straight from the `Kairos/` folder. There's no build step.
- Persistence is one account-wide SavedVariable, `KairosDB`: `global` settings, `profiles[charKey][specID]`, `flight` (recorder) and `probes`. It reaches disk only on logout or `/reload`.
- The C# SimC translator (SPEC §8.2) is in `translator/` (.NET 10, no NuGet packages): it generates Arcane Sunfury and Demonology APLs in their spec folders, with coverage reports under `translator/golden/` (see `translator/README.md`). Planned but not built: the C# replay harness (SPEC §8.3). Generated Lua will be committed and never hand-edited (D21).

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
- Translator tests: `pwsh -File translator/test.ps1` from the repo root (.NET 10 SDK plus a Lua interpreter; it finds the LuaLS binary). Goldens are never updated by the tests; regenerate as `translator/README.md` describes and review the diff.
- Lint: `luacheck .` (config in `.luacheckrc`). Type and API checks: LuaLS with Ketho's WoW API annotations (`.luarc.json`; the VS Code extension adds the annotations).
- In game: the `Kairos/` folder is junctioned into `C:\Games\World of Warcraft\_retail_\Interface\AddOns\Kairos`. `/reload` after edits, with `/console scriptErrors 1` on. `/kairos status` confirms it loaded.
- In-game data, read offline (the user doesn't need to run commands or paste reports):
  - SavedVariables: `C:\Games\World of Warcraft\_retail_\WTF\Account\ANGELUS35C\SavedVariables\Kairos.lua`, written on `/reload`, logout or exit. Check its timestamp; data from the current play session isn't there until one of those happens.
  - Combat logs: `C:\Games\World of Warcraft\_retail_\Logs\WoWCombatLog-*.txt`. Kairos turns logging on at login.
  - `tools/kairos-dump.lua` (`probes`, `fights`, `summary`, `events`, `combatlog`, `salvo`, `apl`, `watch`) reads both. Run it with the LuaLS binary if there's no `lua` on PATH.
  - `salvo` replays a log through `Specs/MageArcane/Salvo.lua` and scores it; rerun it on every new log before and after changing `Salvo.GAINS`, and don't tune on the log you report as validation.
  - `apl` compares the APL on the log's true state with Kairos (the APL on the Salvo and Cumulative Power estimates, each also shown alone), Assisted Combat (from the recorder) and the player's casts, per APL line. Decisions are cast starts for cast-time spells and successes otherwise; the recorder is aligned to cast successes. Matched recorder cast order bounds instant/channel samples, preventing a post-cast pick from grading that cast when GetTime coalesces events. A newly applied Bolt proc within 10 ms before Barrage success is treated as that Barrage's effect, unavailable before its press and preserved afterwards.
  - `watch` lines the recorder's spell-watch signatures (`Data/Trace.lua`) up with auras from the log, field by field, and reports whether any field tracks one. Pass aura IDs to check others; by default it checks Overpowered Missiles, with Clearcasting and Arcane Soul as controls.
  - To compare a trace with a combat log, align them by matching casts (recorder `t` is `GetTime()`; `at` has only one-second resolution). A Blast or Prismatic Bolt success and the next queued spell land milliseconds apart; both are real presses.
  - Open-world training dummies drop combat within seconds of a pause, even mid-channel, so one dummy session shows up as many short fights.
- Packaging: BigWigs packager with `.pkgmeta` (`Kairos/Kairos` moves to the package root). No CI yet (D23).

## Releases

The version lives in `## Version` in `Kairos/Kairos.toc` and in `CHANGELOG.md` (Keep a Changelog format, newest first, with an Unreleased section). Bump both together. Update `## Interface` when Blizzard ships a new client build.

The public GitHub repository is `jmusick/kairos`, with `main` as its default branch (D38). Release commits and tags go to GitHub; do not publish to CurseForge yet.

## Notes

- A spec's `probe` table (in its `Spec.lua`) lists spells, auras and powers **by name**, because several Midnight spells are new and their IDs aren't confirmed. Aura names must match the aura, not the spell: the Prismatic Bolt proc is "Prismatic Bolt!" (`1295942`). Put confirmed IDs in `auraIDs`.
- `Specs/MageArcane/APL.lua` is **generated** by the translator from SimC `515f4a3fe9` (D21): never edit it by hand. Change `translator/metadata/mage_arcane.json` or the translator and regenerate (`translator/README.md`); the translator tests fail if the file and the generator disagree. It is in the TOC, before `Specs/MageArcane/State.lua` (`ArcaneState`), which supplies the contract and registers spec 62 with `Engine/APL.lua`. Picks carry `line` (the SimC line) and `label` (`list:action`, `#n` for a repeated action, `(i/k)` for the top-level `|` clause that fired). The hand-written translation it replaced is kept as the tests' reference (`translator/Kairos.Translator.Tests/reference/`).
- `ArcaneState` treats estimates as known; any unknown field read on the evaluated priority path (including rejected earlier rules) forces AC. The queue is withheld until future proc changes are modeled. `ready`/`remains` toggle tags mirror `translator/metadata/mage_arcane.json`. Enemy count includes hostile dummies even if they report no combat. `State:PrevGcd()` uses each spec's `onGcd` spell table, so off-GCD Touch never replaces it. The recorder writes own picks as `src = "kairos"` with `label`, and continues sampling AC as `src = "ac", observed = true` while Kairos supplies the display. The offline scorer excludes these observation-only entries from the displayed stream.
- Arcane's Touch ready now takes the main icon with `immediate = true`, evaluated on current state (not a projected Bolt completion). A Barrage followed immediately by Touch carries `pairedID`/`pairedLabel`, rendered as an overlapping icon and recorded as `paired`/`pairedLabel`; the adapter checks the generated Touch rule with Barrage as `prevGcd` (D35). Unknown follow-up state withholds the overlay; AC fallback never inherits it. `unknownFields` names fallback dependencies in `/kairos why` and recorder `fields`. The Mage Pulse ID is `1241462` (15 s), not racial `260364`; an unmodeled Pulse gain invalidates Salvo until Barrage/read correction. S2 four-piece checks equipped set 2060, with missing item data kept unknown. Movement filters stationary actions, allowing Missiles with Slipstream.
- Surge availability also requires learned, ready Touch (D37, user-requested constraint). This lives in `translator/metadata/mage_arcane.json`, not a hand-edited generated rule or a falsified `ready[SURGE]` value. The independent reference includes this constraint; older replay results predate it.
- `ArcaneState` withholds a repeat manual Orb for 1.5 s after its success while its charges arrive. The guard uses current time even when evaluating at GCD end; Barrage clears it because a new spend can need Orb again. It filters only Orb availability in the adapter, leaving readable Charges, learned spells and physical cooldown/charge tables intact. It expires even if Orb hits nothing. The window is an estimate, not a live impact read.
- Own-APL icons use `C_Spell.GetSpellTexture`'s second return (`originalIconID`) so an active override cannot paint a post-cast Blast recommendation as Bolt. AC retains the currently overridden artwork. Both returns are secret-guarded through Signal. Display listens to filtered cast/channel events after state handlers so lookahead refreshes immediately on start/interruption.
- Demonology (266, D34) has `Spec.lua`, `Demons.lua` (`DemonologyDemons`, an unvalidated own-cast imp estimate), generated `APL.lua` and `State.lua` (`DemonologyState`). Both APL fixtures use SimC `515f4a3fe9`; never hand-edit either generated APL. Hero talents route the APL; before they unlock, `Leveling()` uses the source's shared `soulharvest` priorities with learned-spell gating. Hidden Demonic Core counts remain unknown: a lit Demonbolt glow gives presence; count-sensitive picks require the same spell for all 1–4 possible counts, otherwise AC. Infernal Bolt/Ruination require their overrides; Ruination is free. Demo has no scored live replay yet (`tools/kairos-dump.lua apl` is Arcane-only).
- A spec's optional `resource = { power, token, key }` selects its traced resource. Trace records Arcane Charges as `ac`, Soul Shards as `shards`, and never assumes every spec uses Arcane Charges. Secret resources are skipped in the recorder and force AC when the live pick depends on them.
- The Keybinds map keeps its last full build if a rebuild hits secret reads in combat, and retries at most once a second. Don't make it rebuild every frame.
- The display refreshes on a throttled `OnUpdate` (`KairosDB.global.updateInterval`, 0.1 s by default) plus a few events. Keep per-refresh work small: SPEC §7.3 targets under 0.5 ms per evaluation.
