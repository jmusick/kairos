# Kairos: Specification

> **Status:** Draft 0.5. Addon 0.2.0 includes Arcane Sunfury and experimental Demonology modules: generated APLs, live state adapters and secrecy probes. Live agreement is still being validated.
> **Target:** World of Warcraft Retail, Midnight (12.x)
> **Last updated:** 2026-10-30

*Kairos* (καιρός) is Greek for "the right moment," the instant when acting matters most. The addon's job is to point at that moment: what to press next.

---

## 1. Summary

Kairos is a Hekili-style rotation helper for WoW Retail. Midnight's 12.0 API changes broke Hekili structurally: "secret values" hide combat state, and the combat log is gone from the addon API.

Kairos **recommends** and never **acts**. It shows the player what to press next. It never presses anything for them.

**The plan is addon-first.**

- Kairos is a pure Lua addon that reconstructs hidden combat state from what the client still exposes, the same approach Tuono took.
- It runs SimulationCraft APLs that an offline tool translates into Lua.
- Screen reading (an external app reading pixels) is a **fallback tier**. We build it only if addon-only can't reach Hekili-level accuracy. That call is made once, after the Arcane Mage prototype (§10).

### Decision log

| # | Date | Decision |
|---|---|---|
| D1 | 2026-10-29 | **Never send input to the game.** No keystrokes, mouse, or controller events, in any build or tier. |
| D2 | 2026-10-29 | **Screen reading is allowed as a fallback**, including screen-reading secret values. |
| D3 | 2026-10-29 | **Addon-only is the goal.** If it reaches the success bar, there's no external app. *(Supersedes the earlier "v1 = addon + app" decision.)* |
| D4 | 2026-10-29 | **SimC APLs are the source of truth.** An **offline translator** turns `.simc` into Lua that ships with the addon. The goal is all specs eventually. |
| D5 | 2026-10-29 | **First spec: Arcane Mage.** |
| D6 | 2026-10-29 | **The fallback decision is global, made after Arcane alone.** If Arcane works addon-only, we proceed addon-only for everything. |
| D7 | 2026-10-29 | **v1 display:** current spell plus 1 queued spell, with keybind text. Hekili-style **cooldown toggle** on a keybind (§7.5). |
| D8 | 2026-10-29 | **Scope: DPS and tank specs.** Healers are out of scope for now. |
| D9 | 2026-10-29 | **Validate offline with `WoWCombatLog.txt` replays.** The combat log is never read live. |
| D10 | 2026-10-29 | **Target content: Mythic+ and raid.** These have the tightest restrictions, so they're the design case. Open world is the test bed. |
| D11 | 2026-10-29 | **Success = "feels like Hekili"** (metric in §9). |
| D12 | 2026-10-29 | **Private for now** (visibility superseded by D38). Tuono is **reference only**: we start fresh and credit its research. |
| D13 | 2026-10-29 | **Primary UI is Blizzard's default** action bars and frames, for keybind detection now and for C2 later if needed. |
| D14 | 2026-10-29 | **Fallback-tier app (if built): C#/.NET, Windows-only.** The offline translator is C# too. |
| D15 | 2026-10-29 | **Cooldown toggle off = "just used"**: `ready=false`, and `remains` reads as the full cooldown. |
| D16 | 2026-10-29 | **The Arcane prototype uses the Sunfury hero tree.** Spellslinger comes later. |
| D17 | 2026-10-29 | **When unsure, show Blizzard's pick with an "AC" badge.** Never blank, never a dimmed guess. |
| D18 | 2026-10-29 | **v1 has one toggle: Cooldowns.** It covers major cooldowns, racials, on-use trinkets, and potions. |
| D19 | 2026-10-29 | **Interrupts show as a separate small icon.** They never displace the rotation icon, and they have no toggle. |
| D20 | 2026-10-29 | **SimC is pinned to a commit, with a manual bump.** A script shows the APL diff and the coverage change for approval. |
| D21 | 2026-10-29 | **The generated Lua is committed to the repo.** The addon folder runs straight from a checkout. |
| D22 | 2026-10-29 | **Tests:** Lua unit tests (busted with a WoW API stub that can return secrets), C# golden-file translator tests, and the replay harness. |
| D23 | 2026-10-29 | **Tooling:** LuaLS with Ketho's WoW API annotations, Luacheck, and the BigWigs packager. No CI for now. |
| D24 | 2026-10-29 | **Enemy count comes from enemy nameplates**, which the player keeps on. No manual AoE toggle needed for v1. |
| D25 | 2026-10-29 | **Evocation is rotational.** The Cooldowns toggle doesn't hold it. |
| D26 | 2026-10-29 | **Keybinds:** slot lookup, plus macro-to-spell resolution, plus a manual override list. The player uses some macros. |
| D27 | 2026-10-29 | **Settings use the native Blizzard Settings API**, with no Ace3. Kairos writes its own SavedVariables with per-character and per-spec profiles. |
| D28 | 2026-10-29 | **The display is always visible.** It isn't tied to combat state. |
| D29 | 2026-10-29 | **The main icon is evaluated as of when the current cast or GCD ends** (what to queue next), Hekili-style. |
| D30 | 2026-10-29 | **Out of combat, run the precombat list, then show the opener.** |
| D31 | 2026-10-29 | **Movement-aware:** while moving, prefer instants unless a cast-while-moving effect is active. |
| D32 | 2026-10-29 | **No channel-clip cue in v1.** Arcane Missiles' `interrupt_if` is parsed but not displayed. |
| D33 | 2026-10-29 | **Specs with no Kairos APL** show Assisted Combat's pick with the "AC" badge, consistent with D17. *(Default adopted. Change it if you disagree.)* |
| D34 | 2026-10-30 | **Build an experimental Demonology leveling/Diabolist module alongside unfinished Arcane**, at the user's request for their level 80 Warlock. This does not decide or move the global fallback gate (D6). |
| D35 | 2026-10-30 | **Touch uses the main icon when ready now.** When the selected Barrage should be immediately followed by Touch, show a smaller overlapping Touch icon on Barrage to represent the user's macro. This refines D7/D29 for off-GCD timing without changing the pinned priority list. |
| D36 | 2026-10-30 | **Allow manual enable/disable**, at the user's request. Disabled hides the display and suspends recommendation evaluations; passive state tracking and recording settings remain active. D28 continues to mean visibility is independent of combat while enabled. |
| D37 | 2026-10-30 | **Hold Arcane Surge until Touch is ready at the evaluation boundary**, at the user's explicit request after a delayed mini-burst left Touch 11 s behind Surge. This is a Kairos availability constraint on the pinned list (D4), declared in translator metadata; it does not falsify either spell's physical cooldown. Unknown Touch readiness forces AC when this gate is needed. |
| D38 | 2026-10-30 | **Host publicly at `github.com/jmusick/kairos`, with `main` as the default branch**, at the user's explicit approval. This supersedes D12's private visibility and resolves Q10. Release commits and tags go to GitHub; CurseForge publishing is deferred. Tuono remains reference only. |

---

## 2. Goals and non-goals

### Goals

- **G1:** Show the next spell plus one queued spell with lead time, so the player isn't scanning action bars.
- **G2:** Agree with SimC's APL as closely as Hekili did (§9). Never do worse than Blizzard's Assisted Combat, which is the fallback floor.
- **G3:** Be honest about uncertainty. If a pick depends on state we can't know, degrade visibly (e.g., hide the queued icon). Don't guess silently.
- **G4:** Data-driven rotations. When SimC updates a spec's APL, re-running the translator picks up the change, as long as the expressions it uses are already supported.
- **G5:** Serve accessibility users. People with motor, cognitive, or chronic-pain limits lost their tool when Hekili died, and they are a primary audience.

### Non-goals (hard lines)

- **N1: No input automation (D1).** Kairos never sends keystrokes, mouse events, or controller input to the game. It never ships a "press for me" mode, and it never ships hooks that make adding one trivial. Any external tier exposes read-only data with no action endpoints.
- **N2: No memory reading, injection, or client modification.**
- **N3: No evasion features.** Kairos will have no randomized timing, no "undetected" claims, and no fingerprint scrubbing.
- **N4:** Not a player-facing log analyzer. Combat logs are a **dev/test tool** only (D9).
- **N5:** No healer support for now (D8).

---

## 3. What changed in Midnight (12.0+)

Blizzard's stated principle: *"Addons should not be able to automate combat decisions for the player."* ([Blizzard](https://news.blizzard.com/en-us/article/24244638/how-midnights-upcoming-game-changes-will-impact-combat-addons))

### 3.1 Secret values

During restricted states (combat, encounters, M+, PvP, and some instance maps), many APIs return **secret values**. Addon code can hold these and pass them to certain widget APIs, but it can't inspect them. Comparison, arithmetic, `#`, using one as a table key, and boolean tests on boolean secrets all raise errors. Secrets **can** be drawn: `StatusBar:SetValue`, Cooldown frames, color curves, and `SetAlphaFromBoolean` all accept them. The UI can show the data. Addon logic can't reason about it. ([wiki](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes), [Tuono LEGALITY.md](https://github.com/matt82198/Tuono/blob/main/docs/LEGALITY.md))

### 3.2 Removed or restricted

Everything here must be **re-verified on 12.1** with the probe (§8).

| Data | Status | Source |
|---|---|---|
| `COMBAT_LOG_EVENT_UNFILTERED` | Gone from the addon API | wiki, Tuono |
| Primary resources | Secret. Tuono found Energy secret *even out of combat*. Mana is untested | Tuono probe |
| Spell cooldowns | Secret while restricted, unless the spell is flagged non-secret | wiki |
| Auras | Secret while restricted, with a small whitelist | wiki |
| Enemy casts, unit identity in instances | Restricted or secret | wiki |
| Target health | Secret (only `UnitHealthMax` for the player is non-secret) | wiki |

### 3.3 Still readable (the raw material)

| Data | Notes | Source |
|---|---|---|
| `C_AssistedCombat.GetNextCastSpell()` | Blizzard's pick, not flagged secret in the API docs | Blizzard API docs |
| Player's own spellcast events | `UNIT_SPELLCAST_*` for the player are non-secret | wiki |
| Secondary resources | Combo points, Holy Power, Runes, and probably **Arcane Charges** (*verify*) | Blizzard, wiki, Tuono |
| "Is this spell usable?" booleans | Never secret. Invert them to bound resources | Tuono |
| Spell activation overlay (proc glow) | Proc *presence*, though not always the stack count | Tuono |
| Talents, gear, set bonuses, action bar layout, bindings | Readable, at least out of combat | — |
| `C_Secrets.*`, `C_RestrictedActions` | Report what is secret *right now* | Tuono probe |

---

## 4. Baseline: Blizzard's Assisted Combat

Added in 11.1.7, with two modes: Assisted Highlight and One-Button Rotation. Blizzard says it is **deliberately sub-optimal**. Its known failure modes:

- It recommends buff upkeep mid-fight.
- It suggests spenders at cap.
- It shows a single spell, with no queue.

Kairos uses it as the **fallback floor**, used when a spec has no translated APL or when state is too uncertain. It also serves as a sanity signal.

---

## 5. Prior art (survey, 2026-10-29)

### 5.1 In-game addons

| Project | Approach | Own logic? |
|---|---|---|
| [HekiLight](https://github.com/meruuke/HekiLight), Knickili, [Blizzkili](https://github.com/davethemage/blizzkili), [JustAC](https://github.com/wealdly/JustAC) | Restyles Assisted Combat | No |
| TrueShot (itsDNNS) | "Presentation rules" on top of Assisted Combat | Partial |
| [Tuono](https://github.com/matt82198/Tuono) | **Reconstructs state** (energy model, cooldowns from casts, proc glows) plus its own priority lists. MIT. Only Outlaw Rogue so far | **Yes**, and the closest to Kairos |

### 5.2 Pixel-bridge and external projects

These are relevant only to the fallback tier. In nearly all of them, an addon paints pixels, an external reader decodes them, and **the reader then sends keystrokes** (which Kairos never does).

| Project | Pipeline | Midnight-era? |
|---|---|---|
| [EZWowX2 / EZPixelDumperX2](https://github.com/liantian-cn/EZWowX2) | Addon draws **secret values** as pixels → local HTTP JSON → rotation program. Successor M.I.D.N.I.G.H.T says 12.1 forced a rewrite | Yes |
| [RuneReader](https://github.com/station384/RuneReader) + Recast | Code39/QR barcodes → C#/OpenCV → input. Says every source "can't read the data after 12.0" | Pre-12.0 |
| [WowPixelRotationBot](https://github.com/hankerspace/WowPixelRotationBot), [hekili-rotation-bot](https://github.com/hongwt/hekili-rotation-bot), [wow-rotation-bot](https://github.com/geexmmo/wow-rotation-bot) | Addon pixels or screenshots → key sender | Pre-12.0 |
| "Undetected 2026 rotation bot" repos | **Likely malware or scam lures.** Don't clone or run them | — |

**The gap:** nobody has an open, multi-spec engine that reconstructs state and runs SimC APLs inside the addon sandbox. That's Kairos.

---

## 6. Architecture

### 6.1 Tier 1: addon-only (primary)

```
 dev time                                    in game
 ────────                                    ───────
 simc/ActionPriorityLists/*.simc             WoW client APIs (non-secret)
        │                                           │
        ▼                                           ▼
 Kairos Translator (C#) ──► Lua APL modules ──► Kairos addon
   + per-spec metadata                          ├─ Signal layer      (§7.1)
     (toggles, durations,                       ├─ State model       (§7.2)
      expression bindings)                      ├─ APL runtime       (§7.3)
                                                ├─ Toggles           (§7.5)
                                                └─ Display           (§7.4)

 WoWCombatLog.txt ──► Replay harness (C#) ──► agreement score (§9)   [offline only]
```

### 6.2 Tier 2: screen-read fallback (only if D6 says so)

This is kept as a design so Tier 1 doesn't block it. Details are in §11.

- **C1:** the addon draws secret values into machine-readable widgets.
- **C2:** an external app reads Blizzard's own UI (Cooldown Manager, unit frames, action bars).
- A C# app fuses those readings with the addon's state and shows its own overlay. It can't send anything back into the game.

---

## 7. Addon components (Lua)

### 7.1 Signal layer

- Every API read goes through a wrapper. It returns `known(v)`, `estimated(v, ±err)`, or `unknown`, and never throws on a secret. It uses `issecretvalue`, `canaccessvalue`, and `C_Secrets.*`.
- It watches restriction state (`C_RestrictedActions`) and re-probes whenever that changes.

### 7.2 State model

This reconstructs what SimC expressions need.

- **Own casts:** `UNIT_SPELLCAST_*` gives `prev_gcd.N`, GCD start, cast and channel timing.
- **Cooldowns and charges:** cast timestamp plus the base cooldown from metadata, with haste, talent, and set-bonus modifiers and known reset or reduction effects. The estimate is corrected against ground truth whenever it's readable (out of combat, or whitelisted spells).
- **Self-applied buffs and debuffs:** a timer starts on our own cast, with the duration from metadata (e.g., Arcane Surge, Touch of the Magi).
- **Procs:** activation-overlay glow gives `buff.X.up`. Stack counts need a per-proc model (see §10.2).
- **Resources:**
  - Secondary resources are read directly.
  - Primary resources come from a spend-and-regen model, bounded by usability booleans.
  - Arcane Orb's own successful cast starts an estimated 1.5 s pending-flight guard: withhold a repeat Orb while its Charge gains arrive, clearing on Barrage or timeout. This uses current time rather than projected GCD end so the icon advances immediately. Readable Arcane Charges and physical cooldown/charge state remain intact; no impact or distance reads are needed.
- **Enemies (D24):** `active_enemies` is the count of hostile, in-combat nameplates, with hysteresis. Filtering by range depends on whether range checks on nameplate units are secret in instances (probe item, Q9).
- **Fight length:** `fight_remains` is the hardest one, since target health is secret. Default heuristics: assume a long fight on bosses, and for M+ trash assume a short fight based on pull size. Confidence is low.
- **Static context:** talents, hero tree, gear, set bonuses, and on-use trinkets, snapshotted out of combat.

### 7.3 APL runtime

- It loads translated APL modules (§8.2), evaluates them each frame or on events, and returns the top action plus 1 queued action.
- **Evaluation time (D29):** the APL is evaluated on a predicted state at **the moment the current cast, channel, or GCD ends**, with the in-progress spell's effects applied (cost, charges, buff changes). The main icon is what to press next, ready for the spell queue window.
- The queued action comes from one more lookahead step: advance the state by the main action's GCD or cast time, then re-evaluate.
- **Precombat (D30):** out of combat, evaluate `actions.precombat`, skipping `snapshot_stats` and already-satisfied buffs such as Arcane Intellect if it's up. Once that list is exhausted, show the first in-combat pick as the opener.
- **Movement (D31):** `moving` and `movement.*` expressions are bound to `GetUnitSpeed("player") > 0` (*verify that it's non-secret*). While moving, cast-time actions are skipped unless the metadata lists a cast-while-moving buff that's up. Arcane has no such effect today, as far as we know.
- **Channels (D32):** `interrupt_if`, `interrupt_immediate`, and `chain` are parsed and preserved in the generated Lua but have no UI in v1.
- **Uncertainty rule:** if the top pick's conditions depend on `unknown` fields, fall back to Assisted Combat's pick and show a subtle "AC" badge. If only the queued pick depends on them, hide the queued icon.
- Throttled to stay well inside Lua's CPU budget. Target: under 0.5 ms per evaluation on average (to validate).

### 7.4 Display (v1, D7)

- **Two icons:** the current spell (large) and the next spell (smaller), Hekili-style.
- Own-APL icons show the exact predicted spell's original artwork, including after consuming a temporary override in lookahead. AC retains live override artwork. Cast/channel start, updates and interruption refresh the display after state handlers, in addition to the throttled update.
- **Keybind text (D26)** on each icon. The lookup order is:
  1. A manual override list, editable in settings.
  2. Default action bar slots: `GetActionInfo` maps a slot to a spell, and `GetBindingKey("ACTIONBUTTONn")`, `MULTIACTIONBAR*`, and so on give the key.
  3. Macros in slots, resolved with `GetMacroSpell` (which handles conditionals like `@cursor` and `mouseover`).
  
  The lookup rebuilds on `ACTIONBAR_SLOT_CHANGED`, `UPDATE_BINDINGS`, and macro updates, and is cached. *Verify that these are readable in combat. If not, snapshot them out of combat.*
- **Interrupt icon (D19):** a small separate icon beside the main pair. It appears when the APL's interrupt line (e.g., `counterspell`) would fire and the interrupt is off cooldown. Enemy cast info is restricted, so Kairos can't know whether the target is casting something interruptible. The icon only means "interrupt available". Whether it should show only while the target is casting depends on the probe (Q8).
- **Off-GCD timing (D35):** Touch ready now takes the main icon with a NOW badge, evaluated on current state. If the next Barrage should be immediately followed by Touch, a smaller Touch icon with a + marker overlaps its upper-right corner. The adapter verifies the generated Touch rule after that Barrage; unknown follow-up state hides the overlay. Other optional off-GCD cues and interrupts remain separate.
- Toggle state indicator: a "CD" pip to the left of the main icon, aligned with its bottom edge, lit or dimmed.
- Movable, scalable, and lockable. X/Y coordinates position the main icon relative to screen center, using sliders and numeric edit boxes. **Visible regardless of combat (D28)** unless manually disabled (D36). Out of combat, it shows the precombat list and the opener (D30).
- **Settings (D27):** a native Blizzard Settings API panel and `/kairos` slash commands. Main icon size has a slider and numeric edit box (32–128, default 52), independent of overall display scale. The paired overlay stays half the main icon size; auxiliary icons retain their sizes. Kairos uses its own SavedVariables (`KairosDB`) with per-character and per-spec profiles. It has no library dependencies.
- *Later:* confidence styling, audio cues, a separate cooldown or defensive lane, and a longer queue.

### 7.5 Toggles (Hekili-style)

- Toggles are **keybinds** registered through `Bindings.xml`, plus slash commands. Flipping an addon flag isn't a protected action, so it works in combat.
- **Cooldowns toggle (the only toggle in v1, D18):** when it's off, every ability tagged `toggle=cooldowns` in the spec metadata is treated as **on cooldown**. That means `cooldown.X.ready = false` and `cooldown.X.remains` reads as its full cooldown. The APL then routes around it, so the player can hold major cooldowns between pulls. For Arcane, that covers Arcane Surge, Touch of the Magi, potions, racials, and on-use trinkets. Evocation is **not** included (D25).
- *Later:* a Defensives toggle for tanks, and a separate Potions toggle if it turns out to be needed.
- **Decided (D15):** "remains = full cooldown". Dependent lines therefore behave as if the cooldown was just pressed, e.g., Touch of the Magi's `cooldown.arcane_surge.remains>30` becomes true and Touch can go out on its own.

### 7.6 Diagnostics

- A **flight recorder**: a ring buffer of state snapshots, each field's source and confidence, and the recommendations. It's saved to SavedVariables for the replay harness.
- `/kairos probe` dumps the secrecy matrix for the spec's spells, auras, and resources.
- `/kairos why` shows which APL line produced the current pick and which fields it read.

---

## 8. Offline tooling (C#)

### 8.1 Secrecy probe (first build task)

A minimal addon plus a script, run on **12.1.x**. It records which values come back secret:

- in the open world, in and out of combat
- in a dungeon (M+ if possible), in and out of combat
- in a raid encounter

It covers every expression Arcane's APL needs (§10.2). Output: a matrix committed to the repo, with the client build number.

### 8.2 Translator

- **Input:** `ActionPriorityLists/default/<spec>.simc` from the [SimC `midnight` branch](https://github.com/simulationcraft/simc/tree/midnight), **pinned to a commit (D20)**. A `bump` script fetches upstream and shows the APL diff plus the coverage-report diff. The pin moves only after approval.
- **Output:** generated Lua modules **committed** to the addon folder (D21), with a header that records the SimC commit and translator version. They are never hand-edited.
- **Parser:** action lists (`actions.X+=/…`), `call_action_list`, `run_action_list`, `variable` (all `op`s), `use_item` and `use_items`, `potion`, `invoke_external_buff`, `cancel_action`, `use_off_gcd`, `line_cd`, `interrupt_if`, and `chain`.
- **Expression compiler:** turns SimC expressions into Lua closures over state-model fields. Each binding is declared in a shared table (`buff.*.up/remains/stack/react`, `cooldown.*.ready/remains/charges_fractional`, `talent.*`, `equipped.*`, `set_bonus.*`, `prev_gcd.N.*`, `gcd.max`, `fight_remains`, `active_enemies`, `mana.pct`, and so on).
- **Per-spec metadata file**, hand-maintained:
  - spell IDs
  - base cooldowns, durations, and charges
  - toggle tags
  - proc stack models
  - actions with no in-game equivalent (`snapshot_stats`, `invoke_external_buff`), which are ignored
- **Coverage report** per spec: each expression marked bound, approximated, or unsupported. It's the to-do list for each spec.

### 8.3 Replay harness

- Reads `WoWCombatLog.txt` (advanced logging on) and rebuilds **ground-truth** state per GCD: auras with stacks, cooldowns, and resources from advanced-log fields.
- Runs the translated APL on the ground truth (the reference pick) and compares it with the addon's flight-recorder picks.
- Outputs the agreement rate per pull and the top disagreement causes, ranked by which field was wrong.
- The client still writing the combat log file on 12.1 is **assumed** (Warcraft Logs depends on it). *Verify.*

### 8.4 Tests and tooling (D22, D23)

- **Lua unit tests:** [busted](https://lunarmodules.github.io/busted/) on Lua 5.1, with a **WoW API stub**. The stub can return secret-like values that error on comparison or arithmetic, so the signal layer's secret handling gets tested. Covers the state model, APL runtime, toggles, and the uncertainty fallback.
- **Translator tests (C#):** golden files, `.simc` in and expected Lua out, plus expression-compiler unit tests.
- **Replay harness:** the end-to-end agreement score (§8.3, §9).
- **Dev tooling:** LuaLS with [Ketho's vscode-wow-api](https://github.com/Ketho/vscode-wow-api) annotations, Luacheck, and the [BigWigs packager](https://github.com/BigWigsMods/packager) for zips. No CI for now. Revisit once there's a remote repo (Q10).

---

## 9. Success metric (D11)

Hekili's output was "the SimC APL evaluated on true state". So:

> **Top-icon agreement** = the share of GCDs where Kairos's current-spell icon matches the APL's pick on ground-truth state from the combat log replay.

- **Target:** ≥ 90% across a full M+ key and a raid boss, on Arcane. (Placeholder. Tune after the first traces.)
- Also tracked: queued-icon agreement, and how often Kairos fell back to Assisted Combat.

---

## 10. Arcane Mage: first spec and the fallback gate

### 10.1 The gate (D6)

After the Arcane prototype, if top-icon agreement reaches the target addon-only, **Kairos stays addon-only for all specs**. If it doesn't, and the gap traces back to state that can't be reconstructed, **Tier 2 gets built**, and the decision applies to the whole project. The replay harness's "top disagreement causes" are the evidence.

### 10.2 What Arcane's APL needs

Taken from `mage_arcane.simc` on SimC `midnight`, last changed 2026-09-06. The APL is short, about 40 action lines. It has a cooldowns list, plus Spellslinger and Sunfury hero-tree branches.

| Expression | Used for | Likely source | Risk |
|---|---|---|---|
| `buff.arcane_charge.stack` | Barrage at 4 charges, Orb and Pulse at <3 | Secondary power, readable directly (*verify*) | Low |
| `prev_gcd.1.*` | Touch of the Magi and Presence of Mind timing | Own cast events | Low |
| `cooldown.arcane_surge.*`, `touch_of_the_magi`, `evocation`, `presence_of_mind` | Cooldown alignment | Cast timestamp + base cooldown | Low to medium (CDR effects) |
| `cooldown.arcane_orb.charges_fractional`, `arcane_pulse` | Orb and Pulse usage | Charge model from casts | Medium |
| `buff.arcane_surge.up/remains`, `debuff.touch_of_the_magi.up` | Burst windows | Self-applied timers | Low |
| `buff.clearcasting.react` (**stacks 0 to 3**) | Missiles usage, `=3` checks | Glow gives presence. **Stacks unknown** | **High** |
| `buff.arcane_salvo.stack/react` (**up to 25**) | Barrage thresholds (≥12, ≥20, =25) | Must model the build rate from casts. Unknown mechanics | **High** |
| `buff.arcane_soul`, `prismatic_bolt`, `overpowered_missiles`, `lustrous_gleam`, `cumulative_power` (S2 4pc) | Various | Glows or own-cast models. Some unknown | Medium to high |
| `mana.pct` | Evocation <10%, cancel at ≥95% | Spend/regen model, plus Arcane Blast usability | Medium (only 2 lines) |
| `active_enemies` vs `variable.aoe_count` | AoE branch | Nameplate count | Medium |
| `fight_remains` | Trinkets, potion, Barrage at end of fight | Heuristic. Target health is secret | Medium (mostly affects cooldowns) |
| `talent.*`, `equipped.*`, `set_bonus.*`, `gcd.max` | Branching, trinkets | Readable static context, haste | Low |

**Arcane is a good stress test.** Most lines are low-risk.

**The Sunfury prototype (D16) narrows the risk.** The Sunfury branch and the shared cooldowns list only test Clearcasting *presence* (`buff.clearcasting.react` as a boolean, or `=0`). The proc glow can cover that. The `react=3` and `<3` stack checks are only in the Spellslinger branch. So for the prototype, the gate mostly comes down to:

1. **Arcane Salvo stacks.** Sunfury compares them against 8, 12, and 25. Find out whether the buff is non-secret, how it builds (per cast? per charge spent?), and whether it can be modeled from own casts.
2. **Arcane Soul** presence and timing.
3. `buff.cumulative_power.stack=8`, only if the Season 2 4-piece is equipped.

The probe (§8.1) checks these first. If Salvo stacks can't be known or modeled, that's the strongest case for C1 or C2.

---

## 11. Tier 2 design (screen-read fallback, contingency)

This section is built only if the gate (§10.1) says so.

- **Bridge strip:**
  - A corner strip of N×N-pixel cells.
  - Header, frame counter, length, payload, and CRC.
  - Calibration cells.
  - Placement that's pixel-exact at any UI scale.
- **Digital cells:** exact data the addon already knows.
- **C1 analog cells:** secret values drawn through widgets, e.g., a StatusBar fill, `SetAlphaFromBoolean`, cooldown swipes. Each has a paired descriptor cell.
- **C2 regions:** calibrated regions of Blizzard's UI: the Cooldown Manager, the player and target frames, and the action bars.
- **App:** C#/.NET on Windows.
  - Captures with Windows.Graphics.Capture or DXGI (Vortice.Windows or ScreenCapture.NET), region-only.
  - OpenCvSharp4 for C2.
  - Fuses data with a source and confidence per field, and runs the same translated APL (via a .NET Lua host or a C# backend from the translator).
  - Shows a transparent click-through overlay. That needs windowed or borderless mode.
  - Read-only local endpoint. No input path (N1).
- **Risks:**
  - Reading secrets works around the stated purpose of secret values, so there's more ToS exposure than Tier 1. C1 is the most clearly circumventive form.
  - Patch fragility: 12.1 broke EZWowX2.
  - Calibration burden.

---

## 12. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| 12.1 changes not yet catalogued | Unknown | **Probe first** (§8.1) |
| Proc stack counts unknowable (Arcane: Clearcasting, Salvo) | The gate fails | Probe these first. Model from own casts. Tier 2 if needed |
| Blizzard tightens more APIs (usability, cast events) | State model degrades | Signal layer degrades to Assisted Combat. Probe every patch |
| Reconstructed cooldowns and buffs drift (haste, CDR, resets) | Wrong picks | Ground-truth correction, replay harness ranks drift causes |
| SimC expression coverage across about 40 specs | Long tail of work | Shared bindings, coverage report, prioritize common expressions |
| SimC APL changes break translation | A spec regresses | Pin commits, translator CI on upstream changes, coverage diff |
| `fight_remains` unknowable | Trinket and potion timing off | Heuristics. Mostly affects cooldowns, which the toggle also gates |
| Tank specs need incoming-damage and health state (secret) | Defensive advice is weak | Rotation-only for tanks in v1. Defensives are a later toggle |
| Lua CPU cost in 20-man raid | FPS impact | Throttle, event-driven updates, precompiled closures |

---

## 13. Open questions

Resolved: D15–D33, including Evocation (D25), keybinds (D26), settings (D27), visibility (D28), evaluation timing (D29), precombat (D30), movement (D31), and channels (D32).

1. **Q6: Which tank spec comes after Arcane?** Deferred until after the gate.
2. **Q8: Interrupt icon timing.** Show it whenever the interrupt is ready, or only while the target is casting? This depends on whether `UnitCastingInfo("target")` presence, not details, is readable in instances. Probe item.
3. **Q9: Nameplate range filtering.** Count every hostile in-combat nameplate, or only those in range of a reference spell? This depends on whether range checks on `nameplateN` units are secret in instances. Probe item.
4. **Q10: Repo hosting.** Resolved by D38: public GitHub repository `jmusick/kairos`, default branch `main`. CurseForge publishing is deferred.
5. **Q12: Spell queue window.** Should the main icon update early enough to queue the next spell (about 400 ms before the GCD ends, by default)? Is `SpellQueueWindow` readable, so it can be matched exactly?

---

## 14. Sources

- Blizzard: [Midnight's changes and combat addons](https://news.blizzard.com/en-us/article/24244638/how-midnights-upcoming-game-changes-will-impact-combat-addons), [Combat philosophy and addon disarmament](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight)
- Warcraft Wiki: [Patch 12.0.0 / Planned API changes](https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes), [C_AssistedCombat.GetNextCastSpell](https://warcraft.wiki.gg/wiki/API:C_AssistedCombat.GetNextCastSpell)
- Blizzard UI source mirror: [AssistedCombatDocumentation.lua](https://github.com/Gethe/wow-ui-source/blob/live/Interface/AddOns/Blizzard_APIDocumentationGenerated/AssistedCombatDocumentation.lua)
- Tuono: [README](https://github.com/matt82198/Tuono), [LEGALITY.md](https://github.com/matt82198/Tuono/blob/main/docs/LEGALITY.md), [RESEARCH-MIDNIGHT.md](https://github.com/matt82198/Tuono/blob/main/docs/RESEARCH-MIDNIGHT.md)
- SimulationCraft: [mage_arcane.simc (midnight)](https://github.com/simulationcraft/simc/blob/midnight/ActionPriorityLists/default/mage_arcane.simc)
- Icy Veins: [Blizzard relaxing more addon limitations](https://www.icy-veins.com/wow/news/blizzard-relaxing-more-addon-limitations-in-midnight/)
- GitHub projects as linked in §5.
