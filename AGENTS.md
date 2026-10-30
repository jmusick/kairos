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

- **Module pattern:** each file opens with `local _, Kairos = ...` and registers with `local X = Kairos:NewModule("X")`, which also sets `Kairos.X`. Modules may define `OnInit` (SavedVariables ready) and `OnLogin` (character and spec known). Core calls them in TOC order, so a module may use modules listed above it at file scope, and any module at runtime.
- **Events:** use `Kairos:On(event, fn)` for client events and `Kairos:Fire`/`Kairos:On` with a `KAIROS_` prefix for internal messages (`KAIROS_PROFILE_CHANGED`, `KAIROS_TOGGLE_CHANGED`, `KAIROS_PLAYER_CAST`, `KAIROS_COMBAT_CHANGED`, `KAIROS_RESTRICTIONS_CHANGED`). For unit events use `Kairos:OnUnit(event, unit, fn)`, which filters in the client. Never compare a unit token from a payload in Lua: it can be secret.
- **Secret values:** every read of combat state goes through `Kairos.Signal` (`Read`, `ReadField`), which returns `{ state = "known"|"estimated"|"unknown", value, reason }` and never throws. Don't compare, do arithmetic on, index, `#`, concatenate or `tostring` a value without checking it with `issecretvalue` first. Secrets may be passed to widgets that accept them; logic may not branch on them.
- **Uncertainty (D17, G3):** when the main pick depends on unknown state, show Assisted Combat's pick with the AC badge. When only the queued pick does, hide the queued icon. Never show a blank or dimmed guess.
- **Defaults:** `DB.lua` holds every default (`globalDefaults`, `profileDefaults`). New settings go there, not ad hoc in a module. Read per-spec settings through `Kairos.profile`, which is replaced on spec change, so never cache it in a local.
- **APIs:** prefer `C_*` namespaces, falling back to legacy globals where an API moved. Guard anything that may not exist (`C_X and C_X.Fn`). Check names against Blizzard's generated docs ([wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/live/Interface/AddOns/Blizzard_APIDocumentationGenerated)) or Ketho's annotations rather than memory, since Midnight renamed and restricted many.
- **New files** go into `Kairos/Kairos.toc` in dependency order, the README file table, and get a spec in `tests/`.
- **Tests:** specs use only the busted subset `tests/run.lua` implements (`describe`, `it`, `before_each`, `assert.are.equal/same`, `assert.is_true/is_false/is_nil/is_not_nil`, `assert.truthy/falsy`, `assert.matches`, `assert.has_error/has_no_error`). Add to the runner if a spec needs more. `tests/wow_stub.lua` resets every global the addon reads; when the addon starts calling a new API, stub it there. Use `Stub.Secret()` to test secret handling.

## Commands

- Tests: `busted` from the repo root (Lua 5.1). Without busted: `lua tests/run.lua`, or run `tests/run.lua` with the `lua-language-server.exe` bundled in the LuaLS VS Code extension, which works as a Lua interpreter.
- Lint: `luacheck .` (config in `.luacheckrc`). Type and API checks: LuaLS with Ketho's WoW API annotations (`.luarc.json`; the VS Code extension adds the annotations).
- In game: the `Kairos/` folder is junctioned into `C:\Games\World of Warcraft\_retail_\Interface\AddOns\Kairos`. `/reload` after edits, with `/console scriptErrors 1` on. `/kairos status` confirms it loaded.
- Packaging: BigWigs packager with `.pkgmeta` (`Kairos/Kairos` moves to the package root). No CI yet (D23).

## Releases

The version lives in `## Version` in `Kairos/Kairos.toc` and in `CHANGELOG.md` (Keep a Changelog format, newest first, with an Unreleased section). Bump both together. Update `## Interface` when Blizzard ships a new client build.

## Notes

- `Probe.EXTRA[specID]` lists spec-specific spells, auras and powers **by name**, because several Midnight spells are new and their IDs aren't confirmed. Prefer names there until the probe confirms IDs.
- The Keybinds map keeps its last full build if a rebuild hits secret reads in combat, and retries at most once a second. Don't make it rebuild every frame.
- The display refreshes on a throttled `OnUpdate` (`KairosDB.global.updateInterval`, 0.1 s by default) plus a few events. Keep per-refresh work small: SPEC §7.3 targets under 0.5 ms per evaluation.
