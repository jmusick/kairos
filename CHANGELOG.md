# Changelog

All notable changes to Kairos are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Chained Arcane Missiles (recast mid-channel) no longer halve the Salvo and Cumulative Power estimates in game. The new channel's start event arrives before its cast event and used to give the still-open channel the new end time.
- Auto-probing stayed off for existing installs because the saved setting kept the old default. A one-time SavedVariables migration (schema 2) turns it on.
- The end-of-fight trace marker is written immediately. Previously it was delayed and could land in the next fight when combat restarted quickly. The after-fight aura read is now a separate `after` entry.
- The probe checks aura secrecy against each aura's own spell ID instead of the ID of the spell that applies it, and shows which ID it used.
- The probe no longer reports spec spells as missing when they're already probed from the Assisted Combat rotation list (Evocation).

### Changed

- The addon is organized by purpose: `Core/`, `Engine/`, `Data/`, `UI/`, and `Specs/<Spec>/` for spec-specific code. Arcane's metadata (probe lists, aura IDs) moved out of the probe into `Specs/MageArcane/Spec.lua`, read through a new spec registry (`Kairos:NewSpec`, `Kairos:CurrentSpec`). The Salvo estimator is now `Specs/MageArcane/Salvo.lua` (`Kairos.ArcaneSalvo`).
- The probe and trace track the Prismatic Bolt proc as "Prismatic Bolt!" (`1295942`), not the spell.

### Added

- Trace records a signature of each watched spell's visible state when it changes (Arcane: Missiles' override, icon, counts, glow and action button), to test whether the secret Overpowered Missiles proc is visible in game.
- `tools/kairos-dump.lua watch` lines those signatures up with auras from the combat log and reports whether any field tracks one. On the first session it found that nothing visible tracks Overpowered Missiles (the counts are secret in combat, and the glow tracks Clearcasting).
- Cumulative Power estimator (`Specs/MageArcane/CumulativePower.lua`) for the Season 2 Arcane 4-piece, which is secret in combat. It's built by Missiles channels, consumed at 8 by Arcane Blast or Prismatic Bolt, and expires after 12 s. It records to the flight recorder and drives the replay; it got `= 8` right on 98% of 372 decisions (`docs/probe/12.1.5-70575-cumulative-power.md`).
- A hand-written Arcane Sunfury APL (`Specs/MageArcane/APL.lua`, from SimC `515f4a3fe9`) with line-by-line tests. It's a stopgap until the translator generates it, and isn't loaded in game yet.
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
