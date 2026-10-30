# Changelog

All notable changes to Kairos are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
