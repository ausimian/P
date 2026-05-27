# A BEAM-native checker for P — `mix pcheck`

A design for systematically *checking* (not just running) P programs compiled to Elixir, driven
from the host project as `mix pcheck`. Companion to [DESIGN.md](./DESIGN.md), which specifies the
Elixir *runtime* backend; this document specifies a checker layered on top of that runtime.

The goal: take a P model already compiled to a mix project (per DESIGN.md), and explore its
schedules under a controlled scheduler, using the generated spec monitors as the safety oracle and
the existing trace recorder as the witness — reporting a replayable counterexample when a property
is violated.

## Why this is feasible (and why the BEAM is a good host)

Two facts make this much smaller than "reimplement Coyote":

1. **PChecker/Coyote is, at its core, a *stateless* controlled-concurrency tester.** It does not
   snapshot and roll back arbitrary program state. It re-executes the program from the initial
   state many times, making *different scheduling decisions* each run, guided by an exploration
   strategy (random, probabilistic/PCT, fair). State-hashing dedup is an *optional* enhancement on
   top, not the foundation. So the hard prerequisite is **control over scheduling and
   nondeterminism**, not cheap checkpoint/restore.

2. **The value-semantics tax that dominates the C# implementation is free on the BEAM.** P data
   types have value semantics (deep-copy-on-assign, structural `==`). In C# that forces every P
   value — and every foreign type — to implement `IPValue.Clone`/`Equals`. On the BEAM, terms are
   immutable (no aliasing, so "clone" is identity) and `==`/`MapSet`/`Map` are already structural.
   The obligation that makes foreign types painful to check in C# largely evaporates for native P
   types in Elixir.

The decisive enabler is that **every observable action in generated code already routes through
`p_runtime`** — `PRuntime.send_event/4`, `PRuntime.create/3`, `PRuntime.announce/3`, the spec
fan-out, and the `PRuntime.Trace` recorder (see DESIGN.md M1–M5). That indirection is exactly the
seam a controlled scheduler hooks into. Checking is therefore mostly a **runtime mode switch plus a
scheduler**, with only one piece of genuinely new codegen (nondeterminism — `$`/`choose`, which the
backend defers today anyway).

## Scope

**In scope.** A controlled scheduler in `p_runtime` (or a companion `p_checker` lib), an exploration
engine with pluggable strategies, safety-violation detection reusing the M5 monitors, replayable
counterexamples, and a `mix pcheck` task run from the host project.

**Out of scope (for now).** Symbolic/SMT reasoning (that is PEx/PVerifier territory; this checker
does *concrete* execution under a controlled scheduler, exactly like Coyote). Changing the C#/Java
verification backends. Distribution (single-node only).

**Honest guarantee.** By default this is a randomized, bounded explorer: "no bug found" means "no
bug in the explored schedules," not a proof — the same caveat that applies to `p check` in its
default mode. Bounded-exhaustive guarantees require the optional stateful layer (C5) and hold only
within the configured bounds.

## Execution model: serialize at handler granularity

P interleaves machines at *handler* granularity: a handler runs atomically to completion —
including internal `raise`/entry events processed front-of-queue — and cross-machine interleaving
happens only *between* those units. This maps onto a single serial loop:

```
loop:
  pool = events currently in flight (held by the scheduler, not in machine mailboxes)
  if pool == [] and no machine is blocked   -> quiescent: normal end of this schedule
  if pool == [] and some machine is blocked -> deadlock: report
  (target, event) = strategy.pick(pool, seed)         # the scheduling decision, logged for replay
  deliver event to target; run its handler to completion
  the sends / creates / choices it produced land back in the pool / decision log
  goto loop
```

Two asymmetric rules realise this on top of the existing runtime:

- **Outgoing actions are redirected.** In check mode `PRuntime.send_event` (and `create`) enqueue
  into the scheduler's pool instead of casting to the target's mailbox. The scheduler becomes the
  *only* thing that ever casts to a machine.
- **Delivery + flush is one atomic step.** To "run one step," the scheduler casts the chosen event
  to the target and then issues `:sys.get_state/1` on it. `:gen_statem` processes any
  `{:next_event, :internal, …}` (entry, raises) *before* serving the system message, so the
  get_state cannot return until the handler and all its internal follow-ups have run to completion.
  This is the same FIFO-flush primitive M5 already uses for synchronous spec fan-out — repurposed
  as the step boundary. While the target runs, no other machine receives anything (their inputs are
  all in the scheduler's pool), so the system is perfectly serialized.

**Oracle, witness, replay come for free from the runtime:**

- *Oracle* — the M5 spec monitors already raise `PRuntime.SafetyViolation` on a failed `assert`.
- *Witness* — `PRuntime.Trace` already records the full causal event trace.
- *Replay* — a schedule is the strategy **seed** plus the **decision log** (the ordered scheduling
  and nondeterministic choices). Re-running with the same seed/log reproduces the counterexample.

## Mechanics that need care

- **Spec fan-out stays at send time.** To preserve trace parity with the runtime (DESIGN.md Q2,
  monitors observe at send time, before enqueue), the synchronous spec notify happens when
  `send_event`/`announce` *enqueues into the pool*, not when the event is later delivered. The
  scheduler does not re-notify on delivery.

- **Creation and entry become scheduled (and atomic with `new`).** P's `new` is constructor-like:
  the created machine's start-state `entry` runs to completion before the creator resumes. In check
  mode, executing a `create` step starts the child and immediately runs its `entry` to completion
  (flush), folding the child's outgoing actions into the pool. (This also surfaces an open question:
  the *production* runtime currently runs entry as an async internal event *after* `init` returns,
  which is weaker than P's synchronous-constructor semantics — the runtime and checker should agree;
  see Open Questions.)

- **Nondeterminism routes through the scheduler.** `$`, `choose()`, `choose(n)`, `choose(coll)` are
  not emitted by the backend yet (deferred in the emitter). They become `PRuntime.choose(…)`: in
  production it draws from `:rand`; in check mode it asks the scheduler, which records the choice in
  the decision log so it replays. These choices are first-class scheduling decisions.

- **`receive` is a blocking point.** P `receive` (also not yet emitted) suspends a machine until a
  matching event arrives — a scheduling point the scheduler must track (mark the machine blocked,
  resumable when a matching event is delivered). Tied to the receive-codegen work; defer.

- **Bounds.** A *max-steps* per schedule bounds non-terminating servers; an *iterations* count
  bounds how many schedules are explored — mirroring Coyote's `--max-steps` / `--iterations`.

## Exploration strategies

Pluggable, behind a `Strategy` behaviour that, given the enabled pool (+ pending nondeterministic
choices) and RNG state, returns the next decision:

- **Random (seeded).** Uniform choice. The MVP; equivalent to Coyote's default random strategy.
- **Probabilistic / PCT.** Priority-based scheduling that provably hits low-probability interleavings
  with bounded bug depth — Coyote's strongest randomized strategy.
- **Fair random.** Random but fairness-preserving, the precondition for liveness checking.
- **(Optional) Systematic DFS.** Enumerate decisions; only meaningful with the stateful layer (C5)
  to prune, otherwise the schedule tree is unbounded for non-terminating systems.

## Liveness (later)

P's `hot`/`cold` temperatures express liveness. The *runtime* M8 plan checks the timed
*bounded-response* approximation (wall-clock deadlines). The *checker* can instead check the untimed
property directly: under **fair** scheduling, detect a cycle in which a monitor stays in a hot state
without ever cooling (a lasso), or apply Coyote's liveness-temperature-threshold heuristic (flag a
monitor that remains hot for N consecutive fair steps). These are two different mechanisms for the
same `hot`/`cold` annotations — worth keeping straight. Liveness depends on fair scheduling and on
the stateful layer (for cycle detection), so it lands after both.

## Optional: stateful exploration (bounded-exhaustive)

A global state is the tuple of every machine's `{state, data}` plus the scheduler's pool (the
multiset of in-flight events). Capturing it is a `:sys.get_state` fan-out; hashing it is a cheap term
hash; comparing is structural `==` — all cheap on the BEAM. With state dedup, a DFS over scheduling
decisions becomes a bounded-exhaustive search with cycle detection. Caveats to document: opaque terms
in state (pids, refs, or a foreign type the user represented with a resource) are not stably
hashable, so either require foreign/checked state to be plain data or ask the user for a canonical
form. This is the strongest mode and the most work; it is an enhancement, not the foundation.

## Packaging

- **`p_runtime`**: add a check-mode flag (default off) and the scheduler process; in check mode,
  `send_event`/`create`/`choose`/`announce` route through the scheduler. The production path is
  unchanged and remains the default — the *same generated lib* runs either way.
- **`p_checker`** (new lib, or a subtree of `p_runtime`): the exploration engine (strategies,
  iteration loop, decision-log replay, counterexample reporting) and the `mix pcheck` Mix task.
- **Codegen impact**: minimal. Only the nondeterminism emission (`$`/`choose`) is new, and it is
  needed for the runtime regardless. Everything else is a runtime concern — no change to the C#
  backend beyond that.
- **UX**: `mix pcheck` runs in the host project: it starts the generated `<Prefix>.Supervisor` in
  check mode under the scheduler, runs N iterations, and on the first violation prints the trace plus
  a replay token (`seed` + strategy). `mix pcheck --replay <token>` re-runs that exact schedule;
  `--iterations`, `--max-steps`, `--seed`, `--strategy` tune the search.

## Soundness contract

Same trust boundary as PChecker:

- All nondeterminism must flow through P primitives (`$`/`choose`) and scheduling. Foreign functions
  must be **deterministic** given their arguments; foreign code must not spawn its own processes,
  block, or do hidden I/O/timing *during checking*, or it escapes the scheduler's control and breaks
  replay. (We cannot enforce this; we document it, as PChecker does.)
- The checker explores schedules of the **P-level model**; it executes foreign functions concretely
  and does not explore paths *inside* them — they are part of the trusted base.

## Phased plan

Each phase runs end-to-end on an existing fixture.

- **C0 — The seam.** Check-mode switch + scheduler skeleton. Route `send_event` to the pool; drive
  one deterministic schedule end-to-end on an existing fixture (e.g. M3 ping/pong) and reproduce the
  same trace the runtime produces. Proves the redirect + step-flush model. No strategy yet.
- **C1 — Randomized `mix pcheck` MVP.** Seeded random strategy, iteration loop, safety-violation
  detection (reuse `PRuntime.SafetyViolation`), replayable counterexample (seed + decision log),
  and the `mix pcheck` task. The first useful checker.
- **C2 — Full nondeterminism + termination.** Emit and route `$`/`choose`; controlled
  creation/entry; deadlock vs. quiescence detection; max-steps / iterations bounds.
- **C3 — Strategies.** PCT/priority-based and fair-random strategies.
- **C4 — Liveness.** Fair scheduling + lasso / temperature-threshold detection wired to spec
  `hot`/`cold`.
- **C5 — Stateful dedup.** Global-state capture + hashing + DFS with cycle detection for
  bounded-exhaustive search.
- **C6 — Polish.** Failing-schedule minimisation (delta-debugging the decision log), coverage stats,
  CI integration, Hex publish.

## Relationship to the runtime backend (DESIGN.md)

- **Reuses**: M5 spec monitors (oracle), `PRuntime.Trace` (witness), the `Spawner`/registry
  (stable machine identity), and the `PRuntime.send_event`/`create`/`announce` indirection (the seam).
- **Requires**: the nondeterminism codegen (`$`/`choose`) the runtime backend currently defers — so
  this work pulls that forward.
- **Overlaps**: liveness. M8 (runtime) is timed bounded-response; C4 (checker) is the untimed
  property via schedule fairness. Same `hot`/`cold` source, different mechanisms.

## Open questions

1. **Entry/creation atomicity.** Should the production runtime make `entry` synchronous with `new`
   (matching P, and what the checker needs) rather than the current async-internal-event approach?
   Resolving this keeps the runtime and checker semantically aligned.
2. **`receive` under the scheduler.** Modelling P `receive` as a tracked blocking point — depends on
   the (not-yet-done) receive codegen.
3. **Enforcing foreign determinism.** We can document but not enforce "no hidden processes/IO/timing
   in foreign code during checking." Is a lint or a sandboxed check-mode shim worth it?
4. **State capture with opaque terms (C5).** How to canonicalise pids/refs/foreign resources for
   stable hashing — or require checked state to be plain data.
5. **Replay robustness.** A decision log is fragile across code edits; seed+strategy replays only if
   the program is unchanged. Do we need a more stable schedule representation?
6. **Fairness flavour for liveness (C4).** Strong vs. weak fairness, and how to choose the bound.

## References

- Coyote (controlled concurrency testing, the engine under PChecker):
  <https://microsoft.github.io/coyote/>
- PCT — "A Randomized Scheduler with Probabilistic Guarantees of Finding Bugs" (Burckhardt et al.)
- `:gen_statem` internal-event ordering and `:sys.get_state` semantics:
  <https://www.erlang.org/doc/man/gen_statem.html>
- The Elixir runtime backend this layers on: [DESIGN.md](./DESIGN.md)
