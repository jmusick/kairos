# Offline SimC APL translator

C#/.NET 10, with no NuGet dependencies. Nothing in this directory reads the game or
sends input; its only output into the addon is the generated APL module. The
fixtures `fixtures/mage_arcane.simc` and `fixtures/warlock_{demonology,affliction,destruction}.simc` are upstream's files byte for byte: SimC `midnight`,
commit `515f4a3fe9`, `ActionPriorityLists/default/<spec>.simc`. The pin is manual; there is no
upstream fetch or automatic update. Generated headers include the pin and translator version.

## Run tests

From the repository root, with the .NET 10 SDK and a Lua interpreter:

```powershell
pwsh -File translator/test.ps1
# Specify Lua explicitly if needed:
pwsh -File translator/test.ps1 -Lua C:/path/to/lua.exe
```

The script isolates SDK/NuGet state under ignored `translator/.local/`, restores
using the package-free NuGet configuration, and runs the C# executable test runner.
It restores the environment variables it changes. The runner uses an explicit
`--lua` argument, then `LUA_EXE`, then the installed VS Code LuaLS interpreter,
then `lua` on PATH. Missing Lua fails the suite rather than silently skipping it.
Lua output targets 5.1 syntax; the local LuaLS interpreter can also run these tests.

Equivalent commands for an ordinary shell:

```sh
dotnet restore translator/Kairos.Translator.Tests --configfile translator/NuGet.Config
dotnet run --no-restore --project translator/Kairos.Translator.Tests
```

Tests include exact Lua and coverage goldens for the full Arcane fixture and a
small control-flow fixture; expression compilation/rejection and actual Lua
numeric/boolean semantics; labels and clauses; coverage completeness; and 20,030
deterministic main/off-GCD state comparisons against an independent hand-written
translation (`Kairos.Translator.Tests/reference/mage_arcane_sunfury.lua`, the APL the
addon shipped before this one), including the boundary cases in
`tests/arcane_apl_spec.lua`. The Arcane golden Lua is the addon's own
`Kairos/Specs/MageArcane/APL.lua`, so the shipped file can't drift from the generator.
The same golden check covers the three Warlock `APL.lua` files; for Demonology an independent
Lua reference makes 10,000 additional Demonology spell-choice comparisons across
the hero routes and shared leveling entry. These compare translations, not live accuracy.
Test output goes under the test project's ignored `obj/`. This validates the
translation against the reference, not against a SimC simulation or a combat-log replay.

## Generate

```sh
dotnet run --project translator/Kairos.Translator -- translator/fixtures/mage_arcane.simc translator/metadata/mage_arcane.json translator/golden/mage_arcane Kairos/Specs/MageArcane/APL.lua
dotnet run --project translator/Kairos.Translator -- translator/fixtures/control.simc translator/metadata/mage_arcane.json translator/golden/control
dotnet run --project translator/Kairos.Translator -- translator/fixtures/warlock_demonology.simc translator/metadata/warlock_demonology.json translator/golden/warlock_demonology Kairos/Specs/WarlockDemonology/APL.lua
dotnet run --project translator/Kairos.Translator -- translator/fixtures/warlock_affliction.simc translator/metadata/warlock_affliction.json translator/golden/warlock_affliction Kairos/Specs/WarlockAffliction/APL.lua
dotnet run --project translator/Kairos.Translator -- translator/fixtures/warlock_destruction.simc translator/metadata/warlock_destruction.json translator/golden/warlock_destruction Kairos/Specs/WarlockDestruction/APL.lua
```

Writes `coverage.json` to the output directory, and the Lua module to the fourth
argument (or `APL.lua` in the output directory without one). Exit codes: **0** no
unsupported records, **2** output written with unsupported records (Arcane today),
**1** invalid input or I/O failure. The goldens are expected output, never updated
by tests: regenerate with the commands above, then review the diffs. Any future
SimC pin update needs an explicit source and coverage review (D20); the automated
bump/diff script is deferred.

## Contract and implementation

The generated module returns a table with `Evaluate(state)` and `OffGcd(state)`
methods, called with Lua colon syntax. Each returns `{ spellID, line, label }` or nil:

- `line` is the original SimC assignment (the `Engine/APL.lua` contract's `line`).
- `label` is a short form for reports: `list:action`, then `#n` when the action
  appears more than once in its list (counting every source line, so labels don't
  move as coverage grows), then `(i/k)` when the condition is an `|` of k clauses
  at the top level and clause i fired. Clauses are tested in order, which gives
  the same answer as testing the whole condition.

`SPELLS` maps each metadata spell's `key` (default: the action name upper-cased) to
its ID. The module is exposed as `Kairos.<module>` from the metadata (`ArcaneAPL`).
It is loaded in the TOC before `Specs/MageArcane/State.lua` (`ArcaneState`), which
builds this state and registers the Sunfury wrapper for spec 62 with `Engine/APL.lua`.
The generated file itself remains independent of the live adapter and offline replay.

The caller must provide a complete, plain, **non-secret** state table:

| State field | Meaning |
| --- | --- |
| `salvo`, `clearcasting`, `charges`, `cumulativePower`, `lustrousGleam` | Numeric stacks/charges |
| `soul`, `surgeUp`, `boltReady`, `setS2_4pc` | Booleans |
| `surgeRemains`, `gcdMax` | Seconds |
| `enemies` | Active enemy count |
| `prevGcd` | Last on-GCD spell ID, or nil |
| `ready[id]` | Cooldown-ready boolean; missing entry means false |
| `remains[id]`, `chargesFractional[id]` | Numeric cooldown state; missing entry means zero, as in the reference |
| `known[id]` | False for unlearned spells; optional table, otherwise spells assumed learned |
| `talent[name]` | Boolean or numeric talent rank; missing entry means zero |

`ready`, `remains`, `chargesFractional`, and `talent` tables are required even when
empty. The live adapter tracks unknown Signal fields through read proxies, applies
the cooldown toggle (D15), and falls back to Assisted Combat for unknown state or
unsupported paths. Any unknown read before returning the pick, including a rejected
higher-priority rule, makes that pick uncertain; estimated values count as known.
Missing entries above
are replay conventions, **not** a policy for secret or unknown live reads.

`metadata/mage_arcane.json` owns the module name, spell IDs and their `SPELLS` keys,
availability predicates, toggle tags, and exact expression-to-state bindings. Availability is checked independently of
the rule's `if`: for example, Bolt needs its proc, Orb/Pulse need a full charge,
and Surge/Touch must be ready. Surge additionally requires learned, ready Touch
at the evaluation boundary (D37). This is an explicit user-requested Kairos
availability constraint, absent from the pinned source's Surge condition. Physical
cooldown state remains unchanged, and the independent reference includes the same
constraint. The Mage Pulse ID is corrected to `1241462` against
the pinned Mage source/database (the old `260364` was the Nightborne racial); the
independent reference uses the same corrected ID. This scaffold has no runtime spell-ID discovery or cooldown
model. Cooldown durations, base charges, aura durations, and proc models remain
state-model work. Metadata Lua snippets are trusted developer input.

The parser preserves list order and source line numbers. Lists are Lua functions;
`call_action_list` returns a child pick or resumes the caller when the child returns
nil. On/off-GCD passes traverse the same call graph. Variables are local to each
pass, with supported precombat variable initializers recomputed first. Only `op=set`
is supported; variable bindings must have an earlier supported declaration in source
order. Conditional assignments initialize to zero if never executed. Cyclic list
calls and list redefinitions fail explicitly.

The expression compiler uses precedence parsing for parentheses, unary `!`, `+`,
`-`, arithmetic `+ - *`, SimC's `<?` (max) and `>?` (min) between arithmetic and
comparison, comparisons `= == != < <= > >=`, and logical `& | ^`.
All results are numeric; emitted helpers convert between SimC's numeric truth and
Lua booleans, so `0` is false, comparisons can be used in arithmetic, and `&`/`|`
short-circuit. Exact bindings cover the Sunfury buffs, known cooldowns, all
`talent.*`, the S2 four-piece bonus, `prev_gcd.1.*` for mapped spells,
`active_enemies`, `variable.*`, and `gcd.max`. Buff suffixes are explicitly mapped,
not guessed from names; unlisted fields are unsupported. A binding keyed
`action:name` gives a bare name its meaning inside that action's options (Agony's
`refreshable` is Agony's), and wins over a plain `name` binding. Variables are bound
in a first pass, so a rule may read one its list declares later in source order; a
numeric `default=` option is the variable's value before any assignment.

## Coverage and remaining work

The report contains a record for **every action**, option, complete expression,
and identifier occurrence, with source line/list, status (`bound`, `approximated`,
`unsupported`), and detail. Identifier scanning continues past an unbound token.
Any unsupported condition or option omits the **whole rule** and reports it;
unsupported state is never replaced by a fabricated expression. Binding support
does not imply action support: a Spellslinger expression can be bound while its
action is excluded. Parse failures and recursive calls fail generation outright.

Current Arcane output covers all seven Sunfury rules, the `aoe_count` variable,
default-list routing, Arcane Surge, and off-GCD Touch of the Magi. `chain=1` is
reported as approximated: the spell recommendation is emitted, but channel timing
is not modeled and there is no clip cue (D32).

Unsupported and visible in the checked-in Arcane coverage report:

- Spellslinger, precombat recommendations, interrupts, potions, racials, trinkets,
  `use_item(s)`, `invoke_external_buff`, and `snapshot_stats`.
- Evocation/cancel logic (`mana.pct`, `action.*.channeling`, target debuffs) and
  Presence of Mind (no spell metadata yet).
- Equipment and trinket variables, `fight_remains`, `time`, potion state,
  unmapped buffs/debuffs and set bonuses, `prev_gcd.N` for N other than 1.
- `run_action_list`, variable operations beyond `set`, `line_cd`, `interrupt_if`
  timing and its options, and other unknown options.
- Expression operators outside the subset above, including SimC division/modulo
  syntax, functions, and target selectors.

This is a **partial Sunfury translator**, not a complete SimC APL. The experimental
live adapter supplies cast-boundary prediction, cooldown/stack models and
unknown-field tracking outside the generator. It rejects Spellslinger even when a
cooldown rule could return a pick. The live movement filter prefers instants and
permits Missiles with Slipstream. The queue is withheld because future proc changes
are not modeled. The adapter withholds repeat Orb suggestions for an estimated
1.5 s flight window after a manual Orb, cleared by Barrage or timeout, without
altering the generated Orb rule or its real cooldown/charges. Off-GCD Touch ready now takes the main icon using current state,
independent of cast/GCD projection. For a recommended Barrage, the adapter also asks
the generated Touch rule whether it should immediately follow that Barrage; a known
result becomes an overlapping paired icon. No generated priorities change. Precombat buff upkeep and the
other omissions above remain unsupported. Full one-step lookahead, the C# replay
harness and the upstream bump script are still planned. See the root README for
the live approximations and the first-session scoring procedure.

## Affliction and Destruction

`metadata/warlock_affliction.json` (`Kairos.AfflictionAPL`, spec 265) and
`metadata/warlock_destruction.json` (`Kairos.DestructionAPL`, spec 267) use the same pin
as Arcane (D40). Both exclude the `ogcd` and `items` lists (potions, racials, trinkets,
external buffs). Affliction routes on `hero_tree.soul_harvester`/`hellcaller` (bound to
the Demonic Soul and Wither talents), and its `Leveling(state)` entry enters the
`soul_harvester` list before a hero tree is chosen. Its metadata's
`approximatedOptions` keeps the default list's channel fillers: `early_chain_if` and
`interrupt_if` are reported as approximated (no clip cue, D32) instead of omitting the
rule, and their expressions aren't compiled. Specs without the option are unaffected.

Omitted whole and listed in the coverage reports: every `target_if` and
`cycle_targets` rule (most cleave and AoE DoT spreading, Havoc), `cycling_variable`,
`raid_event.*`, `active_dot.*`, `dot_refreshable_count.*`, Affliction's
`darkglare_active` variable, and Destruction's trinket variables (`floor`, `%`).
Precombat recommendations other than variables remain unsupported in generated code;
both live wrappers map `summon_pet` (Summon Imp, SimC's default) and Grimoire of
Sacrifice themselves.

The plain, non-secret Affliction input adds to the shared fields (`shards`, `enemies`,
`gcdMax`, `fightRemains`, `prevGcd`, `known`, `castable`, `ready`, `remains`, `talent`):

| Field | Meaning |
| --- | --- |
| `agonyRemains`, `corruptionRemains`, `witherRemains`, `seedRemains` | Seconds left on the target's own DoTs |
| `agonyRefreshable`, `corruptionRefreshable`, `witherRefreshable` | Under 30% of base duration |
| `darkglareRemains`, `malevolenceRemains`, `calamityRemains`, `empowermentRemains` | Seconds left on Darkglare and buffs |
| `nightfall`, `shardInstability` | Stacks |
| `seedInFlight`, `setS2_4pc` | Booleans |
| `execute[id]` | Seconds a cast or channel takes, at least a GCD |

Destruction's adds `shards` in tenths, `chargesFractional[id]` (Conflagrate),
`backdraft` stacks, `immolateRemains`/`witherRemains` with their `…Duration` and
`…Refreshable`, `infernalRemains`, `malevolenceRemains`, `ritualMother`,
`ritualOverlord`, `ritualPitLord` (seconds), `demonicArt`, `fiendishCruelty`,
`infernalReady`, `ruinationReady`, `chaosBoltInFlight` (booleans), `targetHealthPct`
and `execute[id]` (with Backdraft's 30% for the casts it speeds). `target.time_to_die`
binds to `fightRemains`. Spell IDs, cooldowns, durations, costs and gains come from the
pinned Warlock initialization, actions and `sc_spell_data.inc` (12.1.0.69587), and still
need the 12.1.5 in-game probe. There is no independent reference translation or replay
score for either spec yet.

## Demonology contract and leveling entry

`metadata/warlock_demonology.json` generates `Kairos.DemonologyAPL` for spec 266
from the same pin as Arcane. `Evaluate(state)` follows the source's hero routing;
`Leveling(state)` enters the shared `soulharvest` list before hero talents unlock,
with the caller gating every unlearned spell. This is an explicit source-list entry,
not a fabricated talent selection or a separately hand-written rotation. Diabolist
is the initial play-test target for the user's level 80 build (D34).

Metadata's optional `entryPoints` maps a Lua method name to a source list. All named
entries share the same supported precombat variable initializers as `Evaluate`.
Missing/excluded/precombat lists, reserved methods and invalid names are rejected.
Specs without this option generate the same Lua as before; Arcane's output is unchanged.

The complete plain, non-secret Demo input is:

| Field | Meaning |
| --- | --- |
| `shards`, `coreStacks`, `imps` | Whole Soul Shards, Demonic Core stacks, Wild Imps |
| `coreUp`, `argusUp`, `infernalReady`, `ruinationReady` | Core presence, Dominion of Argus, active spell replacements |
| `enemies`, `gcdMax`, `fightRemains` | Hostile nameplate count, GCD seconds, estimated fight seconds |
| `known[id]`, `castable[id]`, `ready[id]`, `remains[id]` | Learned spell, movement permission, cooldown availability and seconds |
| `talent[name]` | Hero tree and supported talent booleans/ranks |

The live `DemonologyState` caches spell/talent knowledge, predicts deterministic
effects to cast/GCD end and applies the metadata's cooldown tags. A hidden Core count
is never passed off as an exact count: when the glow proves presence, the wrapper
evaluates all four possible positive counts and accepts only the same spell across
all of them. Otherwise AC is used. Other unknown priority-path reads force AC.
The imp count, timers, cached haste and 300 s fight length are estimates, documented
in the root README. There is no Demo combat-log replay/accuracy score yet.

Coverage: 15 Diabolist and 13 Soul Harvester action lines, plus both hero routing
calls and the `in_opener` variable. The two `target_if` Demonbolt rules are omitted
whole, while their generic Demonbolt fallbacks remain. Items, racials, potion/external
buff recommendations and precombat actions remain unsupported in generated code.
The live wrapper separately maps the source's `summon_pet` upkeep to a learned
Felguard/Imp outside combat. The generated code emits no queued recommendation; the
live adapter derives one by advancing its state past the main pick and re-evaluating.

Spell IDs, costs and base timers were checked against the pinned
[Warlock initialization](https://github.com/simulationcraft/simc/blob/515f4a3fe9/engine/class_modules/warlock/sc_warlock_init.cpp),
[actions](https://github.com/simulationcraft/simc/blob/515f4a3fe9/engine/class_modules/warlock/sc_warlock_actions.cpp),
[pets](https://github.com/simulationcraft/simc/blob/515f4a3fe9/engine/class_modules/warlock/sc_warlock_pets.cpp)
and `sc_spell_data.inc` (build 12.1.0.69587). In particular, Ruination is free and
summons three imps; Infernal Bolt grants three shards. These are source-derived
models awaiting the 12.1.5 in-game probe, not new confirmed probe findings.
