# Offline SimC APL translator scaffold

C#/.NET 10, with no NuGet dependencies. Nothing in this directory reads the game,
changes the addon, or sends input. The supplied `fixtures/mage_arcane.simc` is
preserved from the task's stdin: SimC `midnight`, commit `515f4a3fe9`, upstream
`ActionPriorityLists/default/mage_arcane.simc`. The pin is manual; there is no
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
numeric/boolean semantics; coverage completeness; and 20,028 deterministic
main/off-GCD state comparisons against the hand-written Arcane APL, including
the boundary cases in `tests/arcane_apl_spec.lua`. The reference files are read
without editing them. Test output goes under the test project's ignored `obj/`.
This validates translation against the existing stopgap, not full SimC simulation
or combat-log replay accuracy.

## Generate

```sh
dotnet run --project translator/Kairos.Translator -- translator/fixtures/mage_arcane.simc translator/metadata/mage_arcane.json translator/Kairos.Translator/obj/generated
```

Produces `APL.lua` and `coverage.json`. Exit codes: **0** no unsupported records,
**2** output written with unsupported records, **1** invalid input or I/O failure.
Use an output directory under `translator/` while this scaffold is under review.
The checked-in goldens are expected output, never updated by tests. To intentionally
refresh one, run the CLI with `translator/golden/mage_arcane` (or `control`) as the
output directory, then review both diffs. Any future SimC pin update needs an
explicit source and coverage review (D20); the automated bump/diff script is deferred.

## Contract and implementation

The generated module returns a table with `Evaluate(state)` and `OffGcd(state)`
methods, called with Lua colon syntax. Each returns `{ spellID, line }` or nil.
`line` contains the original SimC assignment for diagnostics. The module is also
exposed as `Kairos.ArcaneAPL`, matching the reference's offline loading shape.
It deliberately has no runtime registration, TOC entry, or installation step:
the current `Kairos.State` does not supply this replay contract yet.

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
empty. Future runtime integration must resolve Signal uncertainty before calling
this module, apply the cooldown toggle in the state adapter (D15), and fall back
to Assisted Combat for unknown state or unsupported paths. Missing entries above
are replay conventions, **not** a policy for secret or unknown live reads.

`metadata/mage_arcane.json` owns spell IDs, availability predicates, toggle tags,
and exact expression-to-state bindings. Availability is checked independently of
the rule's `if`: for example, Bolt needs its proc, Orb/Pulse need a full charge,
and Surge/Touch must be ready. IDs and availability come from the supplied
hand-written reference; this scaffold has no new spell-ID discovery or cooldown
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
`-`, arithmetic `+ - *`, comparisons `= == != < <= > >=`, and logical `& | ^`.
All results are numeric; emitted helpers convert between SimC's numeric truth and
Lua booleans, so `0` is false, comparisons can be used in arithmetic, and `&`/`|`
short-circuit. Exact bindings cover the Sunfury buffs, known cooldowns, all
`talent.*`, the S2 four-piece bonus, `prev_gcd.1.*` for mapped spells,
`active_enemies`, `variable.*`, and `gcd.max`. Buff suffixes are explicitly mapped,
not guessed from names; unlisted fields are unsupported.

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

This is a **partial offline Sunfury translator**, not a complete SimC APL or a
live-ready addon module. In particular, selecting the Spellslinger hero tree is
outside the contract, even if other emitted rules could return a pick. Coverage
omissions must be resolved before production integration. One-step lookahead,
the replay harness, state prediction, unknown-field tracking, movement/precombat
integration, and the upstream bump script are not implemented here.
