using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Plang.Compiler.TypeChecker;
using Plang.Compiler.TypeChecker.AST.Declarations;
using Plang.Compiler.TypeChecker.AST.States;

namespace Plang.Compiler.Backend.Elixir
{
    /// <summary>
    /// Runtime code-generation backend that emits an executable Elixir (BEAM) mix project
    /// from a verified P program. Peer of the PChecker (C#) and PEx (Java) backends; concerned
    /// only with <em>running</em> a P design, not verifying it.
    ///
    /// M1 (walking skeleton): each P machine becomes a <c>:gen_statem</c> module; the generated
    /// <c>&lt;Prefix&gt;.Supervisor</c> starts the (non-spec) machines.
    ///
    /// M2 (payloads and the type system): event/entry payloads are bound and threaded; machine
    /// fields and locals are supported; all primitive types, tuples, named tuples (each distinct
    /// shape becomes a generated <c>defstruct</c> module under <c>&lt;Prefix&gt;.Types</c>) and
    /// seq/set/map map onto built-in Elixir terms.
    ///
    /// M3 (multiple machines and sends): <c>new</c> spawns machines under the DynamicSupervisor;
    /// cross-machine sends resolve targets by opaque id through the registry.
    ///
    /// M4 (defer, raise, ignore): <c>defer E</c> postpones the event, <c>ignore E</c> drops it, and a
    /// non-halt <c>raise E</c> re-delivers <c>E</c> front-of-queue.
    ///
    /// M5 (specs and announce): each P <c>spec</c> becomes a passive <c>:gen_statem</c> monitor that
    /// registers its observed events in <c>init</c> and is started statically by the supervisor
    /// (before any machine). <c>announce</c> and every machine <c>send</c> fan out synchronously to
    /// the observing specs via the runtime. Foreign code arrives in a later milestone.
    ///
    /// Like PObserve, this backend has no compilation stage: the generated mix project is meant
    /// to be consumed as a dependency by a host application, which builds it with the standard
    /// Elixir toolchain (<c>mix</c>). <see cref="ICodeGenerator.HasCompilationStage"/> stays false.
    ///
    /// Logging is a runtime concern: like <c>PCheckerCodeGenerator</c>, the emitted code contains
    /// no logging statements of its own — it calls <c>PRuntime</c> helpers (from the vendored
    /// <c>p_runtime</c> library) which record the trace as a side effect.
    /// </summary>
    public class ElixirCodeGenerator : ICodeGenerator
    {
        public bool HasCompilationStage => false;

        public void Compile(ICompilerConfiguration job)
        {
        }

        public IEnumerable<CompiledFile> GenerateCode(ICompilerConfiguration job, Scope globalScope)
        {
            var modulePrefix = ModulePrefix(job);
            var appName = SnakeCase(modulePrefix);

            // Non-spec machines are the executable state machines. Specs are passive monitors
            // (separate :gen_statem processes that only observe events) — generated below too, but
            // started statically and registered with the runtime's fan-out rather than created.
            var machines = globalScope.Machines.Where(m => !m.IsSpec).ToList();
            var specs = globalScope.Machines.Where(m => m.IsSpec).ToList();

            WarnOnLivenessStates(job, specs);

            // Named-tuple shapes are deduped across the whole program and emitted as struct modules,
            // so collection happens before any machine that constructs/defaults one is generated.
            var types = new ElixirTypeContext(modulePrefix);
            types.CollectFrom(globalScope);

            // `new I(args)` resolves an interface to its implementing machine. P implicitly declares
            // an interface named after each machine, so resolving by name covers the common case
            // (and the explicit-interface case is rare; we fall back to the interface name itself,
            // matching how the PEx backend treats an interface name as a machine name).
            var machinesByName = machines.ToDictionary(m => m.Name);
            string ResolveMachineName(Interface iface) =>
                machinesByName.TryGetValue(iface.Name, out var m) ? m.Name : iface.Name;

            // The supervisor statically starts only "root" machines — those no machine creates with
            // `new`. Everything else is spawned dynamically under the DynamicSupervisor at `new` time;
            // statically starting them too would double-create them.
            var created = new HashSet<string>(
                machines.SelectMany(m => m.Creates.Interfaces).Select(ResolveMachineName));
            var rootMachines = machines.Where(m => !created.Contains(m.Name)).ToList();

            // WriteFile (DefaultCompilerOutput) does not create intermediate directories, and the
            // generated files live under lib/<app>/. Create that directory now, before the
            // orchestrator writes the returned files. PObserve follows the same "touch the output
            // dir during GenerateCode" pattern for its pom.xml.
            Directory.CreateDirectory(Path.Combine(job.OutputDirectory.FullName, "lib", appName));

            var files = new List<CompiledFile>
            {
                GenerateMixExs(modulePrefix, appName),
                GenerateSupervisor(modulePrefix, appName, specs, rootMachines)
            };

            var typesFile = types.EmitTypesFile(appName);
            if (typesFile != null)
            {
                files.Add(typesFile);
            }

            files.AddRange(machines.Select(m => GenerateMachine(modulePrefix, appName, m, types, ResolveMachineName)));
            files.AddRange(specs.Select(m => GenerateMachine(modulePrefix, appName, m, types, ResolveMachineName)));
            return files;
        }

        /// <summary>
        /// Warns when a spec uses <c>hot</c>/<c>cold</c> states. Those temperatures express a
        /// <em>liveness</em> obligation, which is untimed and has no finite witness — so this runtime
        /// backend cannot check it and currently ignores the annotation entirely (hot/cold compile to
        /// ordinary states). Without a warning the liveness property would silently evaporate; a timed
        /// "bounded-response" approximation is planned (DESIGN.md M8).
        /// </summary>
        private static void WarnOnLivenessStates(ICompilerConfiguration job, IEnumerable<Machine> specs)
        {
            foreach (var spec in specs)
            {
                var livenessStates = spec.States
                    .Where(s => s.Temperature != StateTemperature.Warm)
                    .Select(s => s.Name)
                    .ToList();

                if (livenessStates.Count > 0)
                {
                    job.Output.WriteWarning(
                        $"[Elixir backend] spec '{spec.Name}' uses hot/cold state(s) " +
                        $"[{string.Join(", ", livenessStates)}]: the Elixir runtime backend does not check " +
                        "liveness, so these temperature annotations are ignored (see DESIGN.md M8). " +
                        "Safety assertions are still checked.");
                }
            }
        }

        private static CompiledFile GenerateMixExs(string modulePrefix, string appName)
        {
            var file = new CompiledFile("mix.exs");
            file.Stream.Write(
$@"defmodule {modulePrefix}.MixProject do
  use Mix.Project

  def project do
    [
      app: :{appName},
      version: ""0.1.0"",
      elixir: ""~> 1.17"",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # No `mod:` application callback by default: starting machines on Application.start is
  # surprising. The host adds {modulePrefix}.Supervisor to its own supervision tree explicitly.
  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {{:p_runtime, github: ""ausimian/p_runtime"", ref: ""481515a7d16191cef70956db97dd8a58a7474ab9""}}
    ]
  end
end
");
            return file;
        }

        private static CompiledFile GenerateSupervisor(string modulePrefix, string appName,
            IReadOnlyCollection<Machine> specs, IReadOnlyCollection<Machine> rootMachines)
        {
            // The DynamicSupervisor is always present (machines created with `new` are spawned under
            // it via PRuntime.Spawner) and listed first, so it is running before any root machine's
            // entry handler can create children.
            //
            // Specs are started next, before any root machine — each spec registers what it observes
            // in its `init` (synchronously, before its start_link returns), so every observed event
            // is mirrored to it from the first machine send onward. Both specs and root machines are
            // started with their own name as id.
            string Child(Machine m) => $"      {{{modulePrefix}.{m.Name}, %{{id: \"{m.Name}\", args: nil}}}}";
            var statics = string.Join(",\n", specs.Concat(rootMachines).Select(Child));
            var rootBlock = statics.Length > 0 ? ",\n" + statics : "";

            var file = new CompiledFile(Path.Combine("lib", appName, "supervisor.ex"));
            file.Stream.Write(
$@"defmodule {modulePrefix}.Supervisor do
  @moduledoc """"""
  Entry point for the generated P program. The host adds this module to its own
  supervision tree; it owns the DynamicSupervisor that machines are spawned under and
  starts the program's root state machines (those not created by another machine with `new`).

  Generated by the P compiler's Elixir backend.
  """"""
  use Supervisor

  def start_link(init_arg \\ []) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {{DynamicSupervisor, name: PRuntime.MachineSupervisor, strategy: :one_for_one}}{rootBlock}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
");
            return file;
        }

        /// <summary>
        /// Emits one <c>:gen_statem</c> module per P machine, in
        /// <c>[:handle_event_function, :state_enter]</c> mode. State-functions mode is avoided
        /// deliberately: it would require a function named after each state, and P state names are
        /// PascalCase (e.g. <c>Init</c>), which is not a valid Elixir function name. A single
        /// <c>handle_event/4</c> matching on the state atom sidesteps that entirely.
        ///
        /// Machine fields become the <c>defstruct</c> carried as the <c>:gen_statem</c> data.
        /// P's <c>entry</c> runs as a synthetic <c>{:__entry__, payload}</c> internal event queued on
        /// arrival (from <c>init</c> and from every <c>goto</c>), so entry executes in the new state
        /// and any goto payload reaches it.
        /// </summary>
        private static CompiledFile GenerateMachine(string modulePrefix, string appName, Machine machine,
            ElixirTypeContext types, System.Func<Interface, string> resolveMachineName)
        {
            // Stable, unique Elixir keys for the machine's fields; shared between the defstruct here
            // and every field read/write the emitter produces.
            var fields = new NameAllocator();
            foreach (var field in machine.Fields)
            {
                fields.Allocate(field);
            }

            // __id__ carries the machine's opaque instance id (its registry key). It is the single
            // machine identity used for the trace, `this`, and as the `from` of every send. The key
            // starts with `_`, which ElixirNames.Identifier never produces, so no P field collides.
            var structFields = string.Join(", ",
                new[] { "__id__: nil" }.Concat(
                    machine.Fields.Select(f => $"{fields[f]}: {types.Default(f.Type)}")));

            // A spec is a passive monitor: same :gen_statem shape, but on init it registers the set
            // of events it observes with the runtime's fan-out, and it is never created with `new`.
            var kind = machine.IsSpec ? "spec" : "machine";
            var observesLine = "";
            if (machine.IsSpec)
            {
                var events = string.Join(", ", machine.Observes.Events.Select(e => ElixirNames.Atom(e.Name)));
                observesLine = $"\n    PRuntime.observes(id, [{events}])";
            }

            var sb = new StringBuilder();
            sb.Append(
$@"defmodule {modulePrefix}.{machine.Name} do
  @moduledoc """"""
  Generated from P {kind} `{machine.Name}` by the P compiler's Elixir backend. Do not edit.

  Encoded as a :gen_statem in handle_event_function + state_enter mode. P `entry` runs as a
  synthetic `{{:__entry__, payload}}` internal event queued on arrival, so entry executes in the
  new state across every transition. Machine fields are carried in the struct below; handler
  locals are threaded through a `locals` map.
  """"""
  @behaviour :gen_statem

  defstruct [{structFields}]

  # {(machine.IsSpec ? ":temporary — a spec is a passive monitor; if it halts or fails an assertion\n  # (a safety violation, raised as PRuntime.SafetyViolation) it stays down, never restarted." : ":transient — a P machine that halts (stops :normal) is not restarted; only an abnormal\n  # crash would restart it. P machines halt or live forever (see DESIGN.md, Open Question 3).")}
  @doc false
  def child_spec(arg) do
    %{{id: __MODULE__, start: {{__MODULE__, :start_link, [arg]}}, restart: {(machine.IsSpec ? ":temporary" : ":transient")}}}
  end

  # `arg` is %{{id: opaque_id, args: entry_payload}}: a root machine gets it from the supervisor,
  # a dynamically-created one from PRuntime.Spawner. The id is the registry key, so the machine is
  # addressable by id (not pid) the moment start_link returns.
  def start_link(%{{id: id}} = arg) do
    :gen_statem.start_link({{:via, Registry, {{PRuntime.Registry, id}}}}, __MODULE__, arg, [])
  end

  @impl true
  def callback_mode, do: [:handle_event_function, :state_enter]

  @impl true
  def init(%{{id: id, args: args}}) do
    PRuntime.created(id){observesLine}
    {{:ok, {ElixirNames.Atom(machine.StartState.Name)}, %__MODULE__{{__id__: id}}, [{{:next_event, :internal, {{:__entry__, args}}}}]}}
  end

  @impl true
");

            foreach (var state in machine.States)
            {
                EmitState(sb, modulePrefix, machine, state, fields, types, resolveMachineName);
            }

            sb.Append(
@"  # Catch-all: an event the current state neither handles, defers nor ignores is dropped.
  # (P would raise an unhandled-event error; matching that is out of scope for now.)
  def handle_event(_type, _content, _state, _data), do: :keep_state_and_data
end
");

            var file = new CompiledFile(Path.Combine("lib", appName, $"{SnakeCase(machine.Name)}.ex"));
            file.Stream.Write(sb.ToString());
            return file;
        }

        private static void EmitState(StringBuilder sb, string modulePrefix, Machine machine, State state,
            NameAllocator fields, ElixirTypeContext types, System.Func<Interface, string> resolveMachineName)
        {
            var atom = ElixirNames.Atom(state.Name);
            const string indent = "    ";

            ElixirFunctionEmitter NewEmitter(Function fn) =>
                new ElixirFunctionEmitter(machine, fields, fn, types, modulePrefix, resolveMachineName);

            sb.Append($"\n  # ---- state {state.Name} ----\n");

            // state_enter callback.
            sb.Append($"  def handle_event(:enter, _old_state, {atom}, data) do\n");
            sb.Append($"    PRuntime.entered(data.__id__, {atom})\n");
            sb.Append("    :keep_state_and_data\n");
            sb.Append("  end\n\n");

            // entry handler, encoded as the {:__entry__, payload} internal event.
            if (state.Entry != null)
            {
                var emitter = NewEmitter(state.Entry);
                var body = emitter.Render(indent, tail: true, state.Name);
                sb.Append($"  def handle_event(:internal, {{:__entry__, {Pattern(emitter)}}}, {atom}, data) do\n");
                sb.Append(body);
                sb.Append("  end\n\n");
            }
            else
            {
                sb.Append($"  def handle_event(:internal, {{:__entry__, _payload}}, {atom}, _data), do: :keep_state_and_data\n\n");
            }

            // on E ... handlers.
            foreach (var handler in state.AllEventHandlers)
            {
                var ev = handler.Key;
                var evAtom = ElixirNames.Atom(ev.Name);
                switch (handler.Value)
                {
                    case EventDoAction doAction:
                    {
                        var emitter = NewEmitter(doAction.Target);
                        var body = emitter.Render(indent, tail: true, state.Name);
                        sb.Append($"  def handle_event(_type, {{:p_event, {evAtom}, {Pattern(emitter)}}}, {atom}, data) do\n");
                        sb.Append($"    PRuntime.dequeued(data.__id__, {atom}, {evAtom})\n");
                        sb.Append(body);
                        sb.Append("  end\n\n");
                        break;
                    }

                    case EventGotoState gotoState:
                    {
                        var fn = gotoState.TransitionFunction;
                        var emitter = fn != null ? NewEmitter(fn) : null;
                        var body = emitter?.Render(indent, tail: false, state.Name) ?? "";
                        sb.Append($"  def handle_event(_type, {{:p_event, {evAtom}, {Pattern(emitter)}}}, {atom}, data) do\n");
                        sb.Append($"    PRuntime.dequeued(data.__id__, {atom}, {evAtom})\n");
                        sb.Append(body);
                        sb.Append($"    PRuntime.goto(data.__id__, {atom}, {ElixirNames.Atom(gotoState.Target.Name)}, data, nil)\n");
                        sb.Append("  end\n\n");
                        break;
                    }

                    // `defer E` → :postpone the event so :gen_statem re-delivers it after the next
                    // state change; `ignore E` → dequeue and discard. The runtime helpers build the
                    // return and record the trace, so generated code stays logging-free.
                    case EventDefer _:
                        sb.Append($"  def handle_event(_type, {{:p_event, {evAtom}, _payload}}, {atom}, data) do\n");
                        sb.Append($"    PRuntime.defer(data.__id__, {atom}, {evAtom})\n");
                        sb.Append("  end\n\n");
                        break;

                    case EventIgnore _:
                        sb.Append($"  def handle_event(_type, {{:p_event, {evAtom}, _payload}}, {atom}, data) do\n");
                        sb.Append($"    PRuntime.ignore(data.__id__, {atom}, {evAtom})\n");
                        sb.Append("  end\n\n");
                        break;
                }
            }
        }

        // Pattern for the payload position of a clause head: bind it to `payload` only when the
        // rendered body actually uses it (the emitter seeds `locals` from it), otherwise ignore it.
        private static string Pattern(ElixirFunctionEmitter emitter) => emitter?.PayloadUsed == true ? "payload" : "_payload";

        /// <summary>
        /// Derives an Elixir module alias (PascalCase, e.g. <c>ClientServer</c>) from the P project
        /// name. A configurable <c>--module-prefix</c> option is planned but not part of this scaffold.
        /// </summary>
        private static string ModulePrefix(ICompilerConfiguration job)
        {
            var segments = SplitIdentifier(job.ProjectName);
            if (segments.Count == 0)
            {
                return "PGenerated";
            }

            var sb = new StringBuilder();
            foreach (var segment in segments)
            {
                sb.Append(char.ToUpperInvariant(segment[0]));
                if (segment.Length > 1)
                {
                    sb.Append(segment.Substring(1));
                }
            }

            // Elixir module aliases (and the derived snake_case atom) must start with a letter.
            if (!char.IsLetter(sb[0]))
            {
                sb.Insert(0, 'P');
            }
            return sb.ToString();
        }

        /// <summary>
        /// Converts a PascalCase module alias to a snake_case atom/path segment usable as a mix
        /// app name and the <c>lib/&lt;app&gt;/</c> directory (e.g. <c>ClientServer</c> → <c>client_server</c>).
        /// </summary>
        private static string SnakeCase(string modulePrefix)
        {
            var sb = new StringBuilder();
            for (var i = 0; i < modulePrefix.Length; i++)
            {
                var c = modulePrefix[i];
                if (char.IsUpper(c) && i > 0)
                {
                    sb.Append('_');
                }
                sb.Append(char.ToLowerInvariant(c));
            }
            return sb.ToString();
        }

        /// <summary>
        /// Splits a project name into alphanumeric segments, dropping characters that are not valid
        /// in an Elixir identifier (so names like <c>2PhaseCommit</c> or <c>my-proj</c> still yield a
        /// usable module alias).
        /// </summary>
        private static List<string> SplitIdentifier(string name)
        {
            var segments = new List<string>();
            if (string.IsNullOrEmpty(name))
            {
                return segments;
            }

            var current = new StringBuilder();
            foreach (var c in name)
            {
                if (char.IsLetterOrDigit(c))
                {
                    current.Append(c);
                }
                else if (current.Length > 0)
                {
                    segments.Add(current.ToString());
                    current.Clear();
                }
            }
            if (current.Length > 0)
            {
                segments.Add(current.ToString());
            }

            // Elixir module aliases must start with a letter; drop leading all-digit segments.
            return segments.SkipWhile(s => s.All(char.IsDigit)).ToList();
        }
    }
}
