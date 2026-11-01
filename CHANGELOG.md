# Changelog

All notable changes to Kairos are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.4] - 2026-11-01

### Added

- CurseForge publishing configuration for Kairos Rotation Helper (project 1778452), with tagged-release packaging, a project logo and a link to the article explaining the addon's theory.

### Fixed

- Addon packages exclude the offline translator and root development documents, keeping the installable `Kairos/` folder at the ZIP root.

## [0.2.3] - 2026-11-01

### Changed

- Demonology's Wild Imp estimate snaps to Implosion's cast count, which is the imp count, wherever the client exposes it (between pulls). Out of combat, imps keep only whole Firebolts and resume casting 3 s after combat starts.

### Fixed

- Offline Demonology scoring reads a shard energize's amount as the effective gain (the next field is what the cap wasted) and compares whole shards with the client, and it replays the traced Implosion counts as the live adapter would.

## [0.2.2] - 2026-11-01

### Added

- Arcane decision diagnostics preserve current and projected APL inputs, movement source, cast/channel timing, stack/proc estimates and unknown flags, plus physical cooldown and toggle-gated availability. Cast commitments capture the displayed instruction before the start-event lookahead refresh; unchanged icons retain their latest evaluation for analysis. Diagnostics exclude secret values and remain available on uncertainty fallback.
- Recorder entries carry character/spec, session, build/version and Cooldowns-toggle context, with explicit toggle transitions. Bounded per-combat archives retain up to 1,200 cast/commit entries for each of 32 segments after the main flight ring rolls over; omitted entries and retired segments are reported. Recorder clear removes both stores.
- Demonology recommendations record the same decision diagnostics as Arcane (projected contract, movement and cast), so captured evaluations can be rerun offline.
- The recorder also commits at UNIT_SPELLCAST_SENT, and every commit stores the evaluation on screen before the press's GCD began (the client starts the GCD at the keypress, and a refresh often forecast the next GCD before the cast events arrived). The later pick is kept as `forecast`.
- Implosion joins Demonology's spell watch, to test whether any visible field tracks Wild Imps.
- `tools/kairos-dump.lua apl` scores Demonology logs: shards, Demonic Core, procs, Dominion of Argus, cooldowns and Wild Imps from the log; live, AC and player agreement per APL line; imp-estimate and hidden-Core diagnostics; and a check of the log's shard model against the client's traced values. It prefers keypress snapshots, replaces snapshots that already forecast the next GCD with the pick shown before it, and reseeds shards at each combat start. The first live review is in `docs/replay/12.1.5-70688-demonology.md`.

### Fixed

- Demonology: Call Dreadstalkers no longer requires or spends Soul Shards (free in all 7 logged 12.1.5 casts). The Wild Imp estimate lasts six Firebolts instead of five, Implosion with To Hell and Back now leaves the three imps it summons, and imp lifetimes pause while out of combat (imps idle between pulls).
- Demonology no longer keeps recommending Grimoire: Imp Lord after it is cast. The cast replaces the spell's entry, and the out-of-combat cooldown resync that ran in the same instant read the original ID as idle and erased the cooldown the cast had started, which then held for the whole fight. An idle read can no longer cancel the cast's own cooldown within 2 s or while the spell is replaced, and a deferred cooldown (`isEnabled` false) counts as a full cooldown from now.
- Offline APL scoring uses new pre-refresh commitment snapshots to avoid grading a newly started channel's forecast as its start instruction. It merges archived/ring entries without double-counting, applies captured cooldown-toggle, movement/Slipstream and Orb-flight availability, and marks missing new-format context unscored. Legacy scores retain their explicit provisional assumptions. Immediate Touch cues and their queued GCD slots are scored separately alongside the raw display score; captured-input adapter reproduction is reported separately from log-truth agreement. Generated priorities and estimator gains are unchanged.

## [0.2.1] - 2026-10-30

### Changed

- Rewrote the README to explain how Kairos reconstructs combat state from non-secret signals and evaluates its own priorities, with Blizzard Assisted Combat as the fallback. Added the meaning of the name and a status table covering every class and specialization, including prototype limits and validation progress.

## [0.2.0] - 2026-10-30

Generated Arcane Sunfury recommendations and experimental Demonology support. Both still need live validation.

### Fixed

- The CD toggle indicator sits to the left of the main icon, aligned with its bottom edge instead of underneath it, keeping it clear of the Cooldown Manager below.
- A predicted Arcane Blast after a casting Prismatic Bolt now displays Blast's original icon, instead of the still-active Bolt override artwork. Own-APL icons use the original texture return through Signal, and cast/channel events refresh immediately. Interrupted casts restore the current-state pick.
- Arcane Orb no longer stays suggested immediately after its cast while travelling. A 1.5-second pending-flight guard withholds the second Orb, clears on Barrage after a new spend, and times out if nothing is hit. Readable Charges and actual Orb cooldowns stay intact.
- Offline APL scoring respects recorder cast order when several casts/picks share a frame, and no longer counts Barrage's just-generated Bolt proc as available before that same Barrage. Cast-time spells are still scored at cast start. This corrects reported agreement without changing in-game recommendations or estimator gains.
- Arcane Surge now waits until Touch of the Magi is ready at the evaluation boundary. A delayed mini-burst previously allowed Surge to be recommended with 10+ seconds left on Touch. The user-requested alignment guard is declared in translator metadata, with regenerated Lua and boundary/unknown-state tests; physical cooldown estimates remain intact.
- Coordinate edit boxes replace the sliders' numeric labels so the two values no longer overlap. Editors display two decimal places to keep dragged coordinates readable.
- Arcane Pulse now uses the Mage spell `1241462` and its 15-second cooldown rather than the Nightborne racial. After a Pulse, unmodeled Salvo gains force AC until re-anchored. The generated APL and its independent reference were regenerated/corrected together.
- Arcane's four-piece detection checks equipped tier-set pieces rather than treating an absent spellbook passive as proof that the bonus is absent. Lustrous Gleam uses its pinned aura ID. Movement routes around stationary actions and allows Missiles with Slipstream.
- The Arcane replay filters recorder sessions by character/spec and can align from recent casts if the last cast was not logged. Another character's later session no longer prevents Mage alignment. Logging is rechecked at pull/encounter start, respecting the user's logging setting.
- The unlocked display's drag area now fits the main icon, removing the empty blue extension when the queued icon is hidden.
- Demonology now tracks Implosion's 15-second cooldown and checks readiness before recommending it, including when new imps spawn during the cooldown. It stays rotational with Cooldowns off.
- A Barrage cast just after Arcane Soul ended no longer counts as a Soul Barrage in the Salvo estimate. Soul keeps the Barrage glow lit, so the glow going dark inside the timed Soul window now ends Soul, and a Barrage cast at that instant consumed Salvo.
- Chained Arcane Missiles (recast mid-channel) no longer halve the Salvo and Cumulative Power estimates in game. The new channel's start event arrives before its cast event and used to give the still-open channel the new end time.
- Auto-probing stayed off for existing installs because the saved setting kept the old default. A one-time SavedVariables migration (schema 2) turns it on.
- The end-of-fight trace marker is written immediately. Previously it was delayed and could land in the next fight when combat restarted quickly. The after-fight aura read is now a separate `after` entry.
- The probe checks aura secrecy against each aura's own spell ID instead of the ID of the spell that applies it, and shows which ID it used.
- The probe no longer reports spec spells as missing when they're already probed from the Assisted Combat rotation list (Evocation).

### Changed

- `Specs/MageArcane/APL.lua` is generated by the translator instead of hand-written (D21). Picks keep `line` (now the SimC line itself) and add `label` (`list:action`, `#n` for a repeated action, `(i/k)` for the top-level clause that fired), which `tools/kairos-dump.lua apl` groups by and explains under its table. The hand-written translation is kept as the translator tests' reference.
- The addon is organized by purpose: `Core/`, `Engine/`, `Data/`, `UI/`, and `Specs/<Spec>/` for spec-specific code. Arcane's metadata (probe lists, aura IDs) moved out of the probe into `Specs/MageArcane/Spec.lua`, read through a new spec registry (`Kairos:NewSpec`, `Kairos:CurrentSpec`). The Salvo estimator is now `Specs/MageArcane/Salvo.lua` (`Kairos.ArcaneSalvo`).
- The probe and trace track the Prismatic Bolt proc as "Prismatic Bolt!" (`1295942`), not the spell.

### Added

- Main icon size setting with a slider and numeric edit box (32–128, default 52). It is saved per character/spec, applies immediately, and keeps the overlapping Touch icon proportional. Overall display scale remains separate.
- Arcane's Barrage shows a smaller overlapping Touch icon with a + marker when the generated APL calls for Barrage immediately followed by Touch, representing the user's macro. It respects cooldown readiness, uncertainty and the Cooldowns toggle, and records the paired spell/label. Touch ready now takes the main icon with a NOW badge, evaluated on current state so it never anticipates an unlanded Bolt. `/kairos why` explains paired picks and unknown inputs.
- Screen-center X/Y positioning through `/kairos position <x> <y>` and Settings sliders/edit boxes. `/kairos enable` and `disable` resume or suspend the display and recommendation evaluations account-wide.
- Experimental Demonology module for leveling and Diabolist (D34), generated from the existing SimC pin `515f4a3fe9`. It reads learned spells/talents, Soul Shards and proc replacements, models own-cast cooldowns/imp summons, filters cast-time spells while moving, holds major summons with Cooldowns off, and recommends a missing pet outside combat. Unknown state falls back to AC; hidden Core counts are accepted only when every possible count gives the same spell. Demo's probe, watch and recorder collect data automatically; it has not been scored live.
- The translator supports named extra entry points into source lists. Demonology's `Leveling()` enters the shared `soulharvest` priorities before hero talents unlock, with unlearned spells gated. Its generated Lua/coverage are golden checked, plus 10,000 independent spell-choice comparisons across hero and leveling routes.
- Resource traces now follow spec metadata: Arcane Charges keep their `ac` entries and Demonology records `shards`. The offline event reader also prints Demo's modeled imp counts.
- In-game Arcane Sunfury state adapter (`Specs/MageArcane/State.lua`, `ArcaneState`), registered for spec 62 with the generated APL now in the TOC. It builds state at cast/GCD end from readable charges/glows, the existing stack estimators, cast-timed cooldowns and Surge/Soul windows, hostile nameplates and cached out-of-combat context. Cooldowns off holds Surge/Touch as just used. Unknown priority-path inputs, unsupported Spellslinger and moving cast-time picks fall back to AC; the queue remains hidden.
- The flight recorder saves Kairos's own picks as `src = "kairos"` with the APL label, and preserves AC observations while Kairos supplies the display. `tools/kairos-dump.lua apl` scores recorded in-game picks using the existing cast-success alignment, alongside the estimator-only score, per-line agreement, displayed agreement including fallback and AC fallback frequency.
- A partial offline SimC APL translator in C# (`translator/`, SPEC §8.2). It parses action lists, `call_action_list` and `variable` (`op=set`), compiles expressions against bindings in a per-spec metadata file, and writes a Lua module plus a coverage report that lists every unsupported action and expression instead of dropping it. For SimC `515f4a3fe9` it covers Arcane's Sunfury and cooldowns lists, and its output makes the same picks as the hand-written APL on 20,000 random states and on all 654 replayed decisions.
- Trace records a signature of each watched spell's visible state when it changes (Arcane: Missiles' override, icon, counts, glow and action button), to test whether the secret Overpowered Missiles proc is visible in game.
- `tools/kairos-dump.lua watch` lines those signatures up with auras from the combat log and reports whether any field tracks one. On the first session it found that nothing visible tracks Overpowered Missiles (the counts are secret in combat, and the glow tracks Clearcasting).
- Cumulative Power estimator (`Specs/MageArcane/CumulativePower.lua`) for the Season 2 Arcane 4-piece, which is secret in combat. It's built by Missiles channels, consumed at 8 by Arcane Blast or Prismatic Bolt, and expires after 12 s. It records to the flight recorder and drives the replay; it got `= 8` right on 98% of 372 decisions (`docs/probe/12.1.5-70575-cumulative-power.md`).
- Arcane Sunfury APL (`Specs/MageArcane/APL.lua`, from SimC `515f4a3fe9`) with line-by-line tests. The original hand-written version is now the translator tests' reference; generated Lua is loaded in game through `ArcaneState`.
- `tools/kairos-dump.lua apl` replays a combat log and compares, per decision and per APL line, the APL on true state with Kairos (the APL on the Salvo and Cumulative Power estimates), Assisted Combat and the player. On the three test sessions Kairos agreed 93%, Assisted Combat 49% (`docs/replay/12.1.5-arcane-sunfury.md`).
- Arcane Salvo estimator (now `Specs/MageArcane/Salvo.lua`) for Arcane. It rebuilds Salvo stacks in combat from casts, Missiles channels, the Arcane Barrage glow (Salvo at 25) and Arcane Soul timing, re-anchoring on Barrage, the glow and out-of-combat reads. It records its estimate to the flight recorder.
- `tools/kairos-dump.lua salvo` replays a combat log through the estimator and scores it against true stacks, optionally between two times. v1 and v2 (Soul timed from the Surge cast, Missiles +11) each put 90% of decisions on the right side of 12 on a session they hadn't seen. The rest is the random Missiles gain.
- `tools/kairos-dump.lua` prints the estimator's recorded `salvo` entries.
- Automatic probes at login, 3 s into each fight, right after each fight, and at encounter and keystone starts. They're silent, on by default, and stored compactly.
- Fight traces in the flight recorder: Arcane Charges, proc glows, in-combat aura events for known aura instances, and readable stacks of tracked auras before and after each fight.
- Kairos turns on combat logging with advanced logging at login (setting: Combat logging).
- `tools/kairos-dump.lua` reads SavedVariables and combat logs offline: probe matrix, fight timelines, per-fight summary, and the player's casts and tracked aura stacks from a combat log.
- `/kairos probe in <seconds> [label]` runs the probe after a delay, and probe reports gain a Probe revision column.
- The probe learns aura spell IDs whenever player auras change out of combat, so short-lived auras like Arcane Salvo and Arcane Soul get an ID for secrecy checks.
- The probe tracks aura instance IDs and checks the by-spell-ID, by-instance and display-count aura reads.
- The probe checks `GetHaste`, `IsPlayerMoving`, movement events and threat.
- Movement falls back to `PLAYER_STARTED_MOVING` and `PLAYER_STOPPED_MOVING` when unit speed is secret, which it is in combat.
- First probe results, out of combat, in combat and after: `docs/probe/12.1.5-70575-world.md`.
- Arcane Salvo analysis from a fight trace and combat log: `docs/probe/12.1.5-70575-salvo.md`.
- `tools/kairos-dump.lua events` prints the raw recorder stream. Arcane Soul and Intuition are tracked auras.

## [0.1.0] - 2026-10-30

First playable build: the addon foundation and the secrecy probe. No SimC APLs run yet, so every spec shows Blizzard's Assisted Combat pick with an "AC" badge.

### Added

- Display with a main icon, queued icon, interrupt icon, keybind text, AC badge and CD pip. It's always visible, movable, scalable and lockable.
- Keybind lookup from default action bar slots, including paging, bonus bars and macros, with per-spec manual overrides (`/kairos bind`).
- Cooldowns toggle, bindable under Key Bindings > AddOns and available as `/kairos cd`.
- Secrecy probe (`/kairos probe`) that records which client reads are secret in the current context, with optional auto-runs on combat, encounters and keystones, and a copyable Markdown report.
- Flight recorder that saves pick changes and the player's casts to `KairosDB`.
- Native Settings panel and per-character, per-spec profiles.
- Secret-safe signal layer, restriction tracking, and the APL module contract with Assisted Combat fallback.
- Unit tests with a WoW API stub that can return secret values, plus a fallback test runner.
