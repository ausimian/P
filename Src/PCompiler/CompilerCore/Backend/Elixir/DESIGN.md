# P → Elixir Backend

A design document for adding Elixir as a runtime code-generation target to the P language compiler (`p-org/P`), alongside the existing backends (PChecker/C#, PEx/Java, PObserve/Java, PVerifier/Uclid5).

## Motivation

P models communicating state machines that exchange asynchronous, typed events. The BEAM virtual machine — the runtime under Erlang and Elixir — was built for exactly this shape of program: cheap isolated processes with mailboxes, FIFO message delivery per sender, supervision trees for failure handling, and a first-class state-machine abstraction (`:gen_statem`) in the standard library.

The semantic distance between P and `:gen_statem` is unusually small. Most of P's runtime constructs have direct, one-line equivalents on the BEAM rather than requiring an emulation layer. That makes Elixir not just a *possible* target but arguably the most natural one of the three.

This document specifies what the backend should do, how generated code is shaped, and the phased plan to get there.

## Scope

**In scope.** A new backend that emits an executable Elixir project from a verified P program. It is a peer of the existing code generators (`PCheckerCodeGenerator`, `PExCodeGenerator`, `PObserveCodeGenerator`, `PVerifierCodeGenerator`), producing artifacts for *running* a P design — not for verifying it. The closest structural analogue is `PObserveCodeGenerator`: it emits a multi-file project plus a build manifest and has no in-compiler build stage. (Note: there is no standalone C backend in the current tree — the runtime/execution generators are PChecker, which targets C#, and PEx, which targets Java.)

**Out of scope.** PChecker, PEx, PVerifier. The verification backends stay exactly as they are. The Elixir backend consumes the same AST and is concerned only with executable code.

**Conformance bar.** A `.p` source must produce equivalent observable event traces when compiled and run via the C, C#, or Elixir backends. Where P's reference semantics are silent or implementation-defined, Elixir's behaviour should match the C# backend (the more permissive of the two existing ones).

## Architecture

```
┌──────────────────────────┐
│     P source (.p)        │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│   P compiler (C#/.NET)   │
│  ┌────────────────────┐  │
│  │ Frontend + AST     │  │
│  └─────────┬──────────┘  │
│            │             │
│  ┌─────────┴──────────┐  │
│  │ Backends           │  │
│  │  (ICodeGenerator)  │  │
│  │  - PCheckerCodeGenerator  (C#)
│  │  - PExCodeGenerator       (Java)
│  │  - PObserveCodeGenerator  (Java)
│  │  - PVerifierCodeGenerator (Uclid5)
│  │  - ElixirCodeGenerator ◄──┼── new
│  └────────────────────┘  │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│  Generated mix project   │
│   ├── mix.exs            │
│   ├── lib/               │
│   │   ├── <Prefix>/      │
│   │   │   ├── supervisor.ex
│   │   │   ├── <Machine>.ex
│   │   │   └── <Spec>.ex  │
│   └── deps: p_runtime    │
└──────────────────────────┘
```

The backend lives inside the existing C# compiler. It walks the same typed AST the other backends consume and emits Elixir source files plus a `mix.exs`.

A small companion library — call it `p_runtime` — is published to Hex (or vendored). It carries the parts of the runtime that don't need to be regenerated per program: the machine registry, spec/monitor fan-out, halt semantics, structured logging for PObserve compatibility, and any helpers that would otherwise be duplicated in every generated module.

## Generation output

The backend emits **exactly one thing**: a mix project intended to be consumed as a dep by a host application. There is no separate "standalone" or "embedded" mode; if someone wants a runnable artifact, they use `mix release` on a host project that depends on the generated lib. That's the same answer every other Elixir library gives, and it keeps the backend orthogonal to deployment.

Concretely:

- **No `application` callback by default.** The generated `mix.exs` omits `application: [mod: ...]`. Starting machines on `Application.start` is surprising — the host usually wants to control when machines spawn and with what arguments. The host adds `<Prefix>.Supervisor` to its own supervision tree explicitly.
- **An `--auto-start` flag** can be added later if there's demand for it. Inverts the default. Not in v1.
- **A `<Prefix>.Supervisor` module is always generated.** It owns the `DynamicSupervisor` for machines, the registry, and any static spec processes. This is the one entry point the host needs to know about.
- **Configurable module prefix** (`--module-prefix MyApp.P`) so the generated lib doesn't collide with anything in the host namespace. Default is something like `PGenerated` or derived from the `.p` filename.

Deployment, scaffolding, and "how do I run this" all fall out of the standard Elixir toolchain:

- `mix new` if you want a fresh host project to consume the generated lib.
- `mix release` if you want a self-contained runnable artifact.
- `iex -S mix` if you want to poke at it interactively.
- ExUnit if you want to drive it from tests.

None of these need anything from the backend.

## Semantic mapping

| P concept | Elixir / OTP equivalent | Notes |
|---|---|---|
| Machine | A module implementing `:gen_statem`, started under a `DynamicSupervisor` | One module per P machine. |
| Machine reference | `pid()` (or a `{pid, ref}` if you want stable identity across restarts) | Registered in `p_runtime`'s registry. |
| State | A state function (`:gen_statem` in `state_functions` mode) | Or `handle_event_function` mode if states are dynamic. State-functions mode reads more naturally. |
| State entry | `state_enter` callback `({:enter, _Old, Data})` | Enabled via `callback_mode/0`. |
| State exit | Returned from the enter callback of the *next* state, or done in the transition itself | P's exit semantics are subtle here — see Open Questions. |
| Event | Tagged tuple `{:p_event, EventName, Payload}` | Plain atoms for payload-less events. |
| `send target, E, payload` | `:gen_statem.cast(target, {:p_event, E, payload})` | Cast is async and matches P's non-blocking send. |
| `raise E, payload` | `{:next_event, :internal, {:p_event, E, payload}}` action | Front-of-queue, processed before further externals. |
| `goto S` | `{:next_state, S, Data}` | Or `{:next_state, S, Data, Actions}` to attach a raise. |
| `defer E` | `:postpone` action on the matching clause | Re-delivered after next state change. |
| `ignore E` | Catch-all clause returning `:keep_state_and_data` | |
| `halt` | `{:stop, :normal, Data}` | Sends to a stopped pid are dropped; matches P's "send to halted machine is no-op". |
| Spec (monitor) | A separate `:gen_statem` subscribed to relevant events via `p_runtime`'s fan-out | Spec machines are passive observers; the runtime mirrors observed events to them. |
| `announce E` | Fan-out to all spec processes observing `E` | Implemented in `p_runtime` so it stays consistent across machines. |
| Foreign type | Erlang/Elixir term, opaque from generated code's POV | User provides conversion helpers in a foreign module. |
| Foreign function | Direct call to a user-provided module function | Conventional name: `PForeign.<function>(args)`. |

### P types → Elixir types

| P type | Elixir term |
|---|---|
| `int`, `float`, `bool` | `integer()`, `float()`, `boolean()` |
| `string` | `binary()` (UTF-8) |
| `machine` | `pid()` |
| `event` | `atom()` |
| `(t1, t2, ...)` | `{t1, t2, ...}` |
| `(f1: t1, f2: t2)` (named tuple) | struct `%Foo{f1: t1, f2: t2}` generated per declaration |
| `seq[t]` | `list(t)` |
| `set[t]` | `MapSet.t(t)` |
| `map[k, v]` | `%{k => v}` |
| `enum` | `atom()` (from a closed set) |
| `any` | `any()` |

## Generated code: a worked example

Given this P (sketch):

```p
event PING : int;
event PONG : int;

machine Pinger {
  var server : machine;
  start state Init {
    entry (s: machine) {
      server = s;
      send server, PING, 1;
      goto Waiting;
    }
  }
  state Waiting {
    on PONG do (n: int) {
      if (n < 5) {
        send server, PING, n + 1;
      } else {
        raise halt;
      }
    }
  }
}
```

The backend should emit roughly:

```elixir
defmodule PElixir.Pinger do
  @behaviour :gen_statem

  defstruct server: nil

  def start_link(args), do: :gen_statem.start_link(__MODULE__, args, [])

  @impl true
  def callback_mode, do: [:state_functions, :state_enter]

  @impl true
  def init({:Init, server}) do
    {:ok, :Init, %__MODULE__{server: server}, [{:next_event, :internal, :__entry__}]}
  end

  # ---- state: Init ----
  def Init(:enter, _old, _data), do: :keep_state_and_data

  def Init(:internal, :__entry__, %__MODULE__{server: s} = data) do
    :gen_statem.cast(s, {:p_event, :PING, 1})
    {:next_state, :Waiting, data}
  end

  # ---- state: Waiting ----
  def Waiting(:enter, _old, _data), do: :keep_state_and_data

  def Waiting(:cast, {:p_event, :PONG, n}, %__MODULE__{server: s} = data) do
    cond do
      n < 5 ->
        :gen_statem.cast(s, {:p_event, :PING, n + 1})
        :keep_state_and_data
      true ->
        {:stop, :normal, data}
    end
  end

  # Catch-all: postpone unknown events if declared deferred, else ignore.
  def Waiting(_type, _event, _data), do: :keep_state_and_data
end
```

Notes on the shape:

- **`handle_event_function` mode, not `state_functions`.** The sketch above (`def Init`, `def Waiting`) is illustrative but not valid Elixir: P state names are PascalCase, and you cannot `def` an uppercase-named function. The implementation therefore uses `[:handle_event_function, :state_enter]` — a single `handle_event/4` with clauses matching on the state atom (`:"Init"`, `:"Waiting"`). This handles arbitrary P state names without identifier gymnastics and is simpler to generate.
- `:state_enter` mode is enabled even when entry handlers are empty, so the codegen stays uniform.
- P's `entry` is encoded as a synthetic `:__entry__` internal event raised from `init`, rather than running in `init` itself. This keeps the "entry runs in the new state" invariant clean across all transitions.
- `raise halt` is just `{:stop, :normal, _}`. P lowers `raise halt` to `tmp = halt; raise tmp`, so the codegen resolves the raised temporary back to its event to recognise halt.
- Machines run `:transient` under the `DynamicSupervisor`/`Supervisor`, so a normal halt is not restarted (Open Question 3).
- Postpone clauses are generated *above* the catch-all so they take precedence.

## The `p_runtime` library

Owns the cross-cutting pieces:

- **Registry.** `p_runtime` registers each spawned machine so foreign code and specs can address machines by name/id rather than pid. Built on `Registry` from stdlib.
- **Spec fan-out.** When a machine sends an event that any spec observes, `p_runtime` mirrors it to those spec pids. Spec declarations from `.p` files generate a static table the fan-out reads at startup.
- **Announce.** `p_runtime.announce(event, payload)` broadcasts to all spec subscribers. Used for global events.
- **Halt semantics.** Wrapper `p_runtime.send/3` that does the cast and logs a structured "send-to-halted" event when the target pid is dead.
- **Structured logging.** Every send, receive, transition, halt, and announce emits a structured log line. **Logging lives entirely in `p_runtime`, never in generated code** — see the principle note below. The exact shape is our choice (key=value text or JSON); it does not need to match any existing backend's format — see Open Question 4.
- **Test harness hooks.** A small API to drive a generated program deterministically from ExUnit — useful for conformance tests against the C# backend.

The split between generated code and `p_runtime` follows the same principle as the existing backends: anything that varies with the `.p` source is generated; anything that's the same for every P program lives in the runtime lib.

**Logging is a runtime concern, not a codegen concern.** This mirrors how PChecker works: `PCheckerCodeGenerator` emits *no* logging statements — it emits plain calls like `currentMachine.SendEvent(...)`, `RaiseGotoStateEvent<S>(...)`, `Announce(...)`, and the CheckerCore runtime logs as a side effect inside those base-class methods (`LogSendEvent` in `ControlledRuntime.cs:644-656`, `LogGotoState` in `StateMachine.cs:1289-1291`, etc.). The Elixir backend does the same: generated `.ex` modules call `p_runtime` wrappers (send/cast, goto/transition, announce, halt) and stay logging-free; those wrappers emit the log lines. This keeps logging uniform across all machines and concentrates M5's logging work in one library.

## Implementation plan

Phased so each milestone runs end-to-end.

**M1 — Walking skeleton. ✅ Done.** One machine, two states, one event with no payload, halt. No specs, no foreign code, no types beyond `int`. Goal: prove the codegen plumbing on the .NET side and the `:gen_statem` shape on the Elixir side. The harness is a hand-written host mix project that takes the generated lib as a `path:` dep, starts `<Prefix>.Supervisor`, drives a machine from an ExUnit test, and asserts the expected transition trace.

Delivered: `ElixirCodeGenerator` emits one `:gen_statem` per machine and wires the start machines into the supervisor; the `p_runtime` library (vendored at `~/Code/p_runtime`) provides the registry, trace recorder, and `goto`/`halt`/`send`/logging helpers; the fixture and harness live under `Tst/ElixirBackend/M1/` (`Walker.p`, `M1Demo.pproj`, `harness/`). Run: `p compile --mode elixir` in `Tst/ElixirBackend/M1/`, then `mix test` in `harness/`.

**M2 — Payloads and the type system. ✅ Done.** All primitive types, tuples, named tuples, seq/set/map. Generate the struct modules for named tuples. Add `MapSet` and `Map` conversions. No `any` yet.

Delivered: the backend now consumes the lowered (three-address) IR the compiler produces for every non-PVerifier target, so the emitter handles one operation at a time over atomic terms. Event and `entry` payloads are bound from the clause head (the synthetic entry event became `{:__entry__, payload}`, and `goto`/`PRuntime.goto` carry an optional payload); machine fields become the `:gen_statem` `defstruct` data and handler params/locals/temporaries are threaded through a `locals` map, so P's mutable variables work on the immutable BEAM. Statements rebind those two accumulators (`data`, `locals`) in sequence, and an `if` rebinds them from its own value so a branch's writes survive the merge — in *tail* position each branch instead produces the `:gen_statem` return. Expressions cover literals, arithmetic/comparison/boolean ops (int `div`/`rem` vs float `/`), tuple/named-tuple/seq/set/map construction, access and the collection ops (`sizeof`, `keys`, `values`, `in`, add/insert/remove), `default`, casts and string formatting. Each distinct named-tuple shape is deduped by canonical representation and emitted as a `defstruct` module under `<Prefix>.Types` (`types.ex`). Constructs from later milestones (cross-machine send, `new`, defer/ignore, `announce`, loops, non-halt `raise`, function calls) emit a TODO marker and fall through. The fixture and harness live under `Tst/ElixirBackend/M2/` (`Store.p`, `M2Demo.pproj`, `harness/`): a single machine accumulates int / named-tuple / anonymous-named-tuple payloads into seq/set/map/struct fields, and the ExUnit test asserts the resulting state via `:sys.get_state` plus the transition trace. The new `goto` payload changed `p_runtime`'s `goto` to arity 5, so both harnesses now depend on the vendored `p_runtime` via a `path` override.

**M3 — Multiple machines and sends.** `new MachineName(args)` spawning under the `DynamicSupervisor`. Cross-machine sends. The registry. A two-machine ping/pong test.

**M4 — Defer, raise, ignore.** All the queue manipulations. Postpone clauses in the right order. Conformance test: a P program that exercises defer + state transition and asserts the deferred event is re-delivered.

**M5 — Specs and announce.** Spec machines as separate processes. Fan-out from `p_runtime`. The `announce` keyword. PObserve-compatible log lines.

**M6 — Foreign types and functions.** Convention for `PForeign` modules. Type stubs in generated code. Documentation for users on writing foreign bindings.

**M7 — Polish.** `any` type. Better error messages when generated code crashes. CI matrix that runs the conformance suite across C, C#, and Elixir backends. Hex-published `p_runtime`.

**M8 — Distribution (optional).** Allow machines to be spawned on remote BEAM nodes. P doesn't currently model "machines on different nodes" as a first-class concept, but the BEAM allows it transparently. This is genuinely new capability rather than parity, so it's a stretch milestone.

## Open questions

All five were resolved by reading the existing backends (`Src/PChecker/CheckerCore/`,
`Src/PEx/`, `Src/PObserve/`). Question 4 in particular overturned a wrong premise in the
original draft — it is **not** the M5 blocker it first appeared to be. Citations below are to
the source as of this investigation (not pinned to a commit — re-verify if the runtime changes).

1. **State-exit semantics. — RESOLVED.** The C# runtime sequences a `goto` strictly as
   **exit → transition → entry** (`GotoStateAsync`, `StateMachine.cs:1287-1303`:
   `ExecuteCurrentStateOnExitAsync` → `DoStateTransition` → `ExecuteCurrentStateOnEntryAsync`).
   Critically, **halt does not run exit handlers** — `HaltAsync` (`StateMachine.cs:437-451`)
   sets status, closes/disposes the inbox, and calls `OnHalt`, never the exit path.

   *Decision:* Do **not** rely on `:gen_statem`'s `state_enter` for exit (it has no paired
   exit callback). Emit exit-handler statements **inline at the transition site**, in order:
   run exit code → then return `{:next_state, S2, data, [{:next_event, :internal, :__entry__}]}`.
   For `raise halt`, emit `{:stop, :normal, data}` **without** running exit code. No extra
   traced event is needed.

2. **`announce` ordering. — RESOLVED.** Monitors are invoked **synchronously, inline in the
   caller's stack**, with no queue; the caller blocks until the monitor finishes all
   transitions (`AnnounceInternal` → `Monitor` → `MonitorEvent` → `HandleEvent`,
   `StateMachine.cs:265-280`, `Monitor.cs:308-375`). Note `send` *also* notifies monitors
   synchronously **at send time, before enqueuing to the target** (`SendEvent` calls
   `AnnounceInternal` first, `StateMachine.cs:532-545`) — so a spec observes an event when the
   sender sends it, not when the target dequeues it.

   *Decision:* Spec fan-out is **synchronous**, triggered at the send/announce call site in the
   sending machine (not on the target's dequeue). Drop the "async fan-out by default" idea — it
   would change ordering and break trace parity. Monitors can be synchronous dispatch rather than
   independent mailbox processes, since the reference model gives them no queue.

3. **Registry semantics across crashes. — RESOLVED.** Sends to a halted machine are **dropped
   silently** (`Enqueue` returns `EnqueueStatus.Dropped` when `Status.Halted`,
   `StateMachine.cs:898-906`), confirming the cast-to-dead-pid mapping. P machines don't restart.

   *Decision:* Start machines `:transient` under the `DynamicSupervisor` (no restart on
   `:normal` stop); treat an abnormal crash as a halt and surface it to the trace rather than
   silently respawning. Keep the registry id stable and independent of pid.

4. **PObserve log format. — RESOLVED; original premise was wrong, and it's *not* a blocker.**
   The premise that we must "emit the same JSON the C# runtime emits so PObserve sees a
   consistent trace" is false on two counts, both confirmed from the code:

   - **There is no shared cross-backend log format.** Each backend differs. PChecker (C#) emits a
     JSON *testing trace* (`*.trace.json`: `{type, details, clock}` with vector clocks,
     `JsonWriter.cs:327-516`, `PCheckerLogJsonFormatter.cs`) — this is a model-checking/replay
     artifact, not a runtime logging standard. PEx (Java) emits plain **text** lines
     `<LogType> message` to `*_0_0.txt` (`TextWriter.java:36`, `LogType.java`) — neither JSON nor
     the PChecker shape.
   - **PObserve has no fixed input format.** PObserve monitors the logs of an *already-running
     system* and adapts to whatever that system emits via a **user-written `Parser<E>`** that maps
     log lines to `PObserveEvent<PEvent<?>>`. The example parser
     (`Src/PObserve/Examples/LockServerPObserve/.../LockServerParser.java:46-75`) reads
     timestamped, app-specific `key=value` lines — the keys are the *application's* fields, not a
     P-defined schema.

   *Decision:* `p_runtime` emits its own clean structured log (key=value text or JSON — our
   choice), and we **generate (or hand-write) a PObserve `Parser`** that maps it to P events.
   There is nothing to match byte-for-byte, so the earlier vector-clock-reproduction concern is
   moot. This removes the M5 blocker; the only remaining decision is the emitted shape + whether
   to auto-generate the matching parser, both fully in our control.

5. **Distribution model. — DEFERRED (keep interface compatible).** Nothing in the runtime models
   multi-node; this is genuinely new capability (M8 stretch). *Decision:* out of scope for v1,
   but make the registry's machine-id an **opaque type** from day one (not a bare `pid()`) so a
   later `{node, id}` form is non-breaking. Cheap insurance.

## Getting started

Concrete first commits, in order:

1. Fork `p-org/P`. Read `Src/PCompiler/CompilerCore` and the `Backend/` directory to understand the AST and how the existing backends are wired. `PObserveCodeGenerator` is the closest structural analogue (multi-file output, no in-compiler build stage); `PCheckerCodeGenerator` shows the imperative emitter contracts (`IExpressionEmitter`/`IStatementEmitter`).
2. Stub `ElixirCodeGenerator` implementing `ICodeGenerator.GenerateCode(ICompilerConfiguration job, Scope globalScope)`, returning `CompiledFile`s for a fixed `mix.exs` and an empty `lib/<prefix>/supervisor.ex`. Wire it in by: adding `Elixir` to the `CompilerOutput` enum; registering it in `Backend/TargetLanguage.cs`; and adding an `"elixir"` value to `PCompilerOptions.CompilerModes` + `ParseCompilerMode` (and the `.pproj` `<Target>` parser in `ParsePProjectFile.cs`). It is then invoked as `p compile --mode elixir`. The output lands in a per-language subdirectory the compiler creates automatically; a `--module-prefix` option is future work. (`HasCompilationStage` stays `false` — the host builds the generated project with `mix`.)
3. Create the `p_runtime` Elixir project separately. Start with the registry, a no-op logger, and a single `cast/3` wrapper. Publish locally with `mix hex.build` for testing.
4. Implement M1 end-to-end before adding anything from M2. The first machine that round-trips a `.p` source into a running `mix test` is the hard part — everything after is incremental.

## References

- P language: <https://p-org.github.io/P/>
- P repository: <https://github.com/p-org/P>
- `:gen_statem` documentation: <https://www.erlang.org/doc/man/gen_statem.html>
- "Safe Asynchronous Programming with P and P#" (Microsoft Research project page)
- HPTS 2022 talk by Ankush Desai on P in production at AWS
