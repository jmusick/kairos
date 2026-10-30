# Changelog

All notable changes to Kairos are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- Auto-probing stayed off for existing installs because the saved setting kept the old default. A one-time SavedVariables migration (schema 2) turns it on.
- The end-of-fight trace marker is written immediately. Previously it was delayed and could land in the next fight when combat restarted quickly. The after-fight aura read is now a separate `after` entry.

- The probe checks aura secrecy against each aura's own spell ID instead of the ID of the spell that applies it, and shows which ID it used.
- The probe no longer reports spec spells as missing when they're already probed from the Assisted Combat rotation list (Evocation).

### Added

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
