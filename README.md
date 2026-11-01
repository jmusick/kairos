# Kairos

Kairos is an experimental rotation helper for World of Warcraft Retail: Midnight (12.x). It runs SimulationCraft priorities against a model of your combat state, built from the non-secret signals the client still exposes. The goal is to recover useful rotation advice even when the addon cannot read the buffs or cooldowns directly.

*Kairos* (καιρός) is Greek for “the right moment”: the instant when acting matters. The name fits the addon's job, showing what to press next and when to press it.

Version **0.2.3**. The project is still testing whether this approach can reach reliable recommendations in real encounters. It recommends spells; you press them. Kairos never sends input to the game.

## Beyond an Assisted Combat wrapper

An Assisted Combat (AC) wrapper asks Blizzard for its next spell and presents that answer in a different interface, perhaps with larger icons or keybinds. The recommendation still comes from Blizzard.

Kairos builds the state needed by its own priority rules. An offline translator turns pinned SimulationCraft action priority lists (APLs) into Lua shipped with the addon. During play, a spec's state model supplies resources, proc presence, estimated stacks, cooldowns and other inputs to those rules. The resulting recommendation can differ from AC because Kairos evaluates the priorities itself.

That also lets the model account for the spell you are already casting and evaluate what should come next when the cast or global cooldown ends. A Cooldowns toggle lets you hold supported major abilities while continuing the rest of the rotation. The display shows the recommendation's keybind, and `/kairos why` identifies the rule or missing input behind it.

AC remains the fallback. When a spec has no Kairos implementation, or an unknown input affects its evaluated priorities, Kairos uses Blizzard's recommendation with an **AC** badge, when that recommendation is available. An uncertain queued action is hidden. On an unimplemented spec, the current experience is therefore still AC; the table below shows where independent logic exists.

## Reconstructing state from non-secret signals

A hidden value can have observable causes and effects. If your own cast consumes a buff, that cast can anchor a model at zero. If later casts build the buff, the model can track those gains. A readable proc glow may reveal that a threshold has been reached, correcting accumulated error. A readable aura outside combat can supply the next starting value.

The working theory is that enough of a rotation's decision state can be recovered this way. A priority rule often needs to know whether a threshold has been crossed, rather than the exact stack count at every instant. Likewise, knowing when you cast an ability can support a cooldown estimate even when its live timer is hidden.

| Available signal | What Kairos can build from it | Where it can fail |
|---|---|---|
| Your own successful casts and readable cast/channel timing | Previous spell, cooldown start, timed buff windows, expected gains and spending, and progress through a channel | Interruptions, travel time, hidden resets and cooldown reductions need explicit handling. |
| Spell activation glows and readable spell overrides | Proc presence, replacement-spell availability, or a known threshold | A glow does not generally reveal stack count, and several effects may light the same spell. |
| Resources that pass the secret-value checks | Current resource count and deterministic changes from the cast in progress | Readability depends on the resource and context; a secret resource stays unknown. |
| Readable aura, cooldown and charge data outside combat | Starting state and corrections to the running model | Values may become hidden in combat; a missing aura is not proof it is absent when the API hides it. |
| Learned spells, talents, gear and haste cached outside combat | Which rules apply, known mechanics and baseline timings | Missing item data and changes during combat can leave the cache incomplete or stale. |
| Movement events and readable hostile nameplates | Movement restrictions and an approximate enemy count | Nameplates are not a reliable count of enemies in spell range; hidden hostility makes the count unknown. |

The live path is: **read non-secret signals → update the spec model → project the current cast/GCD's effects → evaluate the generated APL → display a spell or fall back to AC**. Projection uses a copy of state so it does not apply a future cast's effects to the running model early. New random procs are not predicted.

Each read goes through a signal layer that distinguishes known, estimated and unknown values. The current adapters accept modeled estimates as usable inputs. They track unknown inputs along the priority path, including higher-priority rules that were tested and rejected; an unknown there forces AC. One prototype also checks all possible values of a hidden proc count and accepts the spell only if every value produces the same recommendation.

**An estimate can still be wrong.** A model may miss a random gain, mistake the cause of a glow, or drift after an unmodeled cooldown reset. AC fallback handles recognized unknowns; it does not prove that every accepted estimate is accurate. Ordinary queued recommendations remain hidden because future proc changes are not modeled.

Kairos does not inspect secret values, read game memory, inject code or modify the client. The current runtime is a pure Lua addon with no library dependencies. It never reads the combat log live.

## Class and specialization status

Status reflects the code in **0.2.3**, not a claim of encounter readiness. **Prototype** means an independent APL and live model exist but still need validation. **Not started** means there is no Kairos rotation model; AC is used when available. **Out of scope** marks healers, which are outside the current DPS/tank plan. The roster includes Midnight's [Devourer specialization](https://worldofwarcraft.blizzard.com/en-us/news/24262570/midnight-embrace-the-void-with-the-devourer-specialization).

| Class | Specialization | Role | Status | Implementation and limits |
|---|---|---|---|---|
| Death Knight | Blood | Tank | Not started | — |
| Death Knight | Frost | DPS | Not started | — |
| Death Knight | Unholy | DPS | Not started | — |
| Demon Hunter | Havoc | DPS | Not started | — |
| Demon Hunter | Vengeance | Tank | Not started | — |
| Demon Hunter | Devourer | DPS | Not started | — |
| Druid | Balance | DPS | Not started | — |
| Druid | Feral | DPS | Not started | — |
| Druid | Guardian | Tank | Not started | — |
| Druid | Restoration | Healer | Out of scope | — |
| Evoker | Devastation | DPS | Not started | — |
| Evoker | Preservation | Healer | Out of scope | — |
| Evoker | Augmentation | DPS / support | Not started | — |
| Hunter | Beast Mastery | DPS | Not started | — |
| Hunter | Marksmanship | DPS | Not started | — |
| Hunter | Survival | DPS | Not started | — |
| Mage | Arcane | DPS | Prototype | Sunfury generated APL and live adapter; Salvo/Cumulative Power estimates, cast-end lookahead, Surge/Touch alignment and Barrage/Touch pairing. Spellslinger, full precombat setup and ordinary queue unsupported. Dummy replays exist; M+/raid validation remains open. [Results and limits](docs/replay/12.1.5-arcane-sunfury.md). |
| Mage | Fire | DPS | Not started | — |
| Mage | Frost | DPS | Not started | — |
| Monk | Brewmaster | Tank | Not started | — |
| Monk | Mistweaver | Healer | Out of scope | — |
| Monk | Windwalker | DPS | Not started | — |
| Paladin | Holy | Healer | Out of scope | — |
| Paladin | Protection | Tank | Not started | — |
| Paladin | Retribution | DPS | Not started | — |
| Priest | Discipline | Healer | Out of scope | — |
| Priest | Holy | Healer | Out of scope | — |
| Priest | Shadow | DPS | Not started | — |
| Rogue | Assassination | DPS | Not started | — |
| Rogue | Outlaw | DPS | Not started | — |
| Rogue | Subtlety | DPS | Not started | — |
| Shaman | Elemental | DPS | Not started | — |
| Shaman | Enhancement | DPS | Not started | — |
| Shaman | Restoration | Healer | Out of scope | — |
| Warlock | Affliction | DPS | Not started | — |
| Warlock | Demonology | DPS | Prototype | Generated Diabolist/Soul Harvester routes and a shared leveling entry; Diabolist is the initial play-test target. Learned-spell gating, shard/proc reads, estimated imps and cooldowns. Hidden Demonic Core counts require agreement across all possible counts. Live review ([dummy and two Timewalking dungeons](docs/replay/12.1.5-70688-demonology.md)): in game 88%, 80% and 88% agreement with the APL vs 75%, 64% and 57% for Assisted Combat. Most misses are Implosion calls from the imp estimate, which now anchors to Implosion's readable cast count between pulls. [Translation coverage](translator/README.md#demonology-contract-and-leveling-entry). |
| Warlock | Destruction | DPS | Not started | — |
| Warrior | Arms | DPS | Not started | — |
| Warrior | Fury | DPS | Not started | — |
| Warrior | Protection | Tank | Not started | — |

## How we test the theory

The addon records its recommendations and observations in a flight recorder. Automatic secrecy probes check what can actually be read on a particular client build and in a particular context. Advanced combat logging is enabled by default for later analysis; probes, recording and logging have settings controls.

After a session, offline tools align the recorder with the combat log by matching casts. They reconstruct the state from the log, run the APL on that state, and compare its choices with the addon's recorded picks and Blizzard AC. This helps separate translation errors, state-model errors and timing or scoring errors. It measures agreement with the implemented APL, rather than DPS or agreement with a full SimulationCraft simulation.

Results and their capture conditions live in [probe and estimator findings](docs/probe/) and [replay reports](docs/replay/). Early dummy results are evidence for particular models and sessions, not proof that the addon is ready for raids or Mythic+. The target is at least 90% main-icon agreement across a full M+ key and a raid boss. That gate remains open; the [specification](SPEC.md) records the design and the conditions for deciding whether addon-only reconstruction is sufficient.

The [offline translator](translator/README.md) also has golden-file and independent reference tests. Its pinned SimC source is `515f4a3fe9`. Unsupported actions and expressions are listed in coverage reports; the translator is partial and does not implement every SimC feature. Generated Lua is committed, so the addon needs no build step.

Tuono's reconstruction research is a reference for this approach; Kairos is a separate implementation. See the [prior-art survey](SPEC.md#5-prior-art-survey-2026-10-29) for context.

Read [Kairos: Rebuilding Priority Recommendations](https://orboro.net/blog/kairos-rebuilding-priority-recommendations) for the theory behind the addon.

## Install for development

The CurseForge project is [Kairos Rotation Helper](https://www.curseforge.com/wow/addons/kairos-rotation-helper). New projects and files require CurseForge moderation before they become available. For development, copy the `Kairos/` folder from a checkout into your Retail `Interface/AddOns/` directory, or junction it there so `/reload` picks up edits:

```powershell
New-Item -ItemType Junction -Path 'C:\Games\World of Warcraft\_retail_\Interface\AddOns\Kairos' -Target 'C:\Users\JD\source\kairos\Kairos'
```

Run `/reload`, then `/kairos status` to confirm the addon loaded. Keep enemy nameplates on for enemy counting. Turn on `/console scriptErrors 1` (or use BugSack) while testing.

The display has keybind text, an AC badge and a Cooldowns indicator. It stays visible regardless of combat while enabled. Native Settings controls cover locking, position, scale, main icon size (32–128), and per-character/spec profiles. The Cooldowns toggle can be bound under **Key Bindings > AddOns > Kairos**; it affects Kairos's supported priorities and does not change Blizzard's AC fallback. Interrupt recommendations are not wired yet.

## Publishing to CurseForge

CurseForge project **1778452** links to this repository. [The release workflow](.github/workflows/release.yml) follows Hidden Lodge's setup: pushing a `v*` tag runs `BigWigsMods/packager@v2` and uploads the ZIP to CurseForge and GitHub Releases. Ordinary branch pushes do not publish. CurseForge's native automatic packaging stays off to avoid duplicate uploads.

The root `.pkgmeta` moves the nested addon to the ZIP root, producing `Kairos/Kairos.toc`, `Kairos/Core/`, and the rest of the addon. The translator, tests, tools and development documents are excluded. The packager adds a release changelog. Generated APLs already live in the addon, so publishing requires no translator build.

Before the first release, add a CurseForge publishing token as the **`CURSEFORGE_API_TOKEN`** repository secret under **Settings > Secrets and variables > Actions**. The workflow maps it to BigWigs' `CF_API_KEY`; GitHub supplies its own `GITHUB_TOKEN` for GitHub Releases. A missing CurseForge token fails the workflow rather than silently skipping that upload. Never commit the token or put it in documentation or logs. No repository webhook is needed. See [BigWigs' workflow documentation](https://github.com/BigWigsMods/packager/wiki/GitHub-Actions-workflow).

For each release, update `Kairos/Kairos.toc` and `CHANGELOG.md` together, commit, create an annotated version tag, and push the commit and tag to GitHub. Tags such as `v0.2.4` become releases; tags containing `alpha` or `beta` get that release type. Check CurseForge's Builds and Files pages for packaging and moderation results. Ordinary branch pushes do not publish a file. Do not move an existing tag to republish different contents.

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

## Collecting and inspecting data

Play, then `/reload` or log out so the game writes SavedVariables. The recorder, traces and probes are saved in `KairosDB`; current-session changes are not on disk until the game saves them.

The 5,000-entry flight ring keeps recent traces and pick changes. Each new entry carries character/spec, session, build/version and Cooldowns-toggle context; toggle transitions are also recorded. Arcane recommendations include both current and projected APL inputs, unknown-field flags, movement source, cast/channel start and end times, modeled physical cooldowns and Orb's pending-flight flag. A cast-start/channel-start snapshot preserves the instruction visible before lookahead advances; successful casts also retain the latest evaluation even if the icon never changed. Secret values are excluded from persisted diagnostics.

Bounded per-combat archives retain cast commitments and successes after the main ring rolls over: by default the last 32 combat segments, up to 1,200 entries each (`global.recorderPulls` and `global.recorderPullEntries` in SavedVariables). Long segments report omitted entries; older segments are retired at the segment limit. Reloading or changing profile starts a new recording context. `/kairos recorder clear` clears both the ring and these archives. These records support decision-point analysis, not a complete history of every display refresh.

- SavedVariables: `C:\Games\World of Warcraft\_retail_\WTF\Account\<ACCOUNT>\SavedVariables\Kairos.lua`
- Combat logs: `C:\Games\World of Warcraft\_retail_\Logs\WoWCombatLog-*.txt`

`tools/kairos-dump.lua` reads these files offline. Use any Lua 5.1+ interpreter, including the one bundled with the LuaLS VS Code extension:

```bash
lua tools/kairos-dump.lua probes <Kairos.lua> [n]
lua tools/kairos-dump.lua fights <Kairos.lua> [n]
lua tools/kairos-dump.lua summary <Kairos.lua>
lua tools/kairos-dump.lua events <Kairos.lua>
lua tools/kairos-dump.lua combatlog <WoWCombatLog.txt> <Kairos.lua> [player]
lua tools/kairos-dump.lua salvo <WoWCombatLog.txt> <player> [from HH:MM:SS [to HH:MM:SS]] [verbose]
lua tools/kairos-dump.lua apl <WoWCombatLog.txt> <Kairos.lua> <player> [from HH:MM:SS [to HH:MM:SS]] [verbose]
lua tools/kairos-dump.lua watch <WoWCombatLog.txt> <Kairos.lua> <player> [auraID ...] [from HH:MM:SS [to HH:MM:SS]] [verbose]
```

`salvo` scores the stack estimator, `apl` scores priority decisions, and `watch` checks whether visible spell-state changes track a hidden aura. Scope and limitations are listed in the status table and replay reports.

`apl` merges the pull archives with the ring and removes overlaps by sequence ID. New captures use pre-refresh cast commitments for sampling, plus captured toggle, movement/Slipstream and Orb availability for the reference. Missing commitment/evaluation context is explicitly unscored. Legacy samples retain their provisional cooldowns-on/stationary assumptions. The raw main-icon score remains visible; NOW Touch cues also have a separate off-GCD comparison and GCD-slot score using the displayed queued spell. These are samples at GCD decisions, not a complete audit of Touch/macro timing. Captured-state reproduction reruns the live adapter on its saved current/projected inputs; it checks reproducibility, not agreement with future truth or DPS. The combat-log reference still reconstructs aura/resource truth at the press, with approximate enemy counts and cooldowns. `verbose` prints evaluation boundaries, stack/proc inputs and availability gates.

For a Demonology log, `apl` rebuilds shards, Demonic Core stacks, Diabolist procs, Dominion of Argus, cooldowns and Wild Imps from the log, and takes talents, learned spells, haste and castability from the captured diagnostic. The log never states shards, so they come from energize events and known costs, seeded per pull from the client's traced reading; the report shows how often the model then matches later readings. It also reports how often the imp estimate matches the log and how often a hidden Core count would force AC. Only captured snapshots are scored, keypress snapshots first; one that already projects past the press is replaced by the display change shown before that GCD began.

## Tests

Lua specs use a WoW API stub that can return secret values:

```bash
busted
# Without busted, run the same specs with a Lua 5.1+ interpreter:
lua tests/run.lua
```

On a Windows development machine with the LuaLS VS Code extension, its bundled interpreter can run the suite:

```powershell
& "$env:USERPROFILE/.vscode/extensions/sumneko.lua-3.19.2-win32-x64/server/bin/lua-language-server.exe" tests/run.lua
```

The extension version in that path must match your installation. Translator tests require the .NET 10 SDK and a Lua interpreter:

```powershell
pwsh -File translator/test.ps1
```

These tests check the implementation and translation; live agreement still needs recorded play sessions.

## Files

The addon is split by what code is for. Anything that applies to one specialization lives under `Specs/`; everything else is spec-agnostic.

| File | Purpose |
|---|---|
| `.github/workflows/release.yml` | Publish tagged addon packages to CurseForge and GitHub Releases with BigWigs |
| `.pkgmeta` | Addon package layout and development-file exclusions |
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
| `Engine/APL.lua` | APL evaluation, module contract and Assisted Combat fallback |
| **`Kairos/Data/`** | **Collection and diagnostics** |
| `Data/Recorder.lua` | Flight ring, toggle/session context, pre-refresh cast commitments and bounded per-combat archives |
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
| `Specs/MageArcane/State.lua` | `ArcaneState`: live contract/prediction, captured-input reproduction, cached context/cooldown models, uncertainty tracking and spec 62 registration |
| **`Kairos/Specs/WarlockDemonology/`** | **Demonology Warlock only** |
| `Specs/WarlockDemonology/Spec.lua` | Spell/aura IDs, traced Soul Shards and the Demo secrecy probe/watch lists |
| `Specs/WarlockDemonology/Demons.lua` | `DemonologyDemons`: own-cast Wild Imp estimate with explicit times for future offline replay |
| `Specs/WarlockDemonology/APL.lua` | Generated Diabolist/Soul Harvester priorities and a shared leveling entry (don't edit) |
| `Specs/WarlockDemonology/State.lua` | `DemonologyState`: learned spells/talents, resources/procs, cooldown and cast-boundary models, movement and uncertainty; registers spec 266 |
| `tests/` | Specs, the WoW API stub, and the fallback runner |
| `translator/` | Offline C# SimC APL translator for Arcane and Demonology, with explicit coverage reports, goldens and reference comparisons |
| `tools/kairos-dump.lua` | Reads SavedVariables and combat logs offline, and replays logs through the Arcane modules |
| `docs/probe/` | Probe and estimator results per client build, with findings |
| `docs/replay/` | APL replays: Kairos, Assisted Combat and the player against the APL on true state |
