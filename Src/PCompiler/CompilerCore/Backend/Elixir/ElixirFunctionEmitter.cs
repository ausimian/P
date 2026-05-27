using System.Collections.Generic;
using System.Linq;
using System.Text;
using Plang.Compiler.Backend.ASTExt;
using Plang.Compiler.TypeChecker.AST;
using Plang.Compiler.TypeChecker.AST.Declarations;
using Plang.Compiler.TypeChecker.AST.Expressions;
using Plang.Compiler.TypeChecker.AST.Statements;
using Plang.Compiler.TypeChecker.Types;

namespace Plang.Compiler.Backend.Elixir
{
    /// <summary>
    /// Emits the body of a single P handler (entry, <c>on E do</c>, or a goto transition function)
    /// as the tail of a <c>handle_event/4</c> clause.
    ///
    /// <para><b>Mutable state on an immutable runtime.</b> P functions mutate machine fields and
    /// locals; Elixir values are immutable. We thread two accumulators through the body: <c>data</c>
    /// (the machine struct, holding the fields) and <c>locals</c> (a plain map holding the handler's
    /// parameters, locals and IR temporaries, pre-seeded with type defaults). A field read is
    /// <c>data.f</c>; a local read is <c>locals.x</c>; a write rebinds the corresponding accumulator
    /// (<c>data = %{data | f: …}</c>). Straight-line code rebinds in sequence; an <c>if</c> rebinds
    /// the accumulators from the value of the <c>if</c> expression so changes in a branch survive it.</para>
    ///
    /// <para><b>Effect vs tail mode.</b> A handler must ultimately yield one <c>:gen_statem</c> return.
    /// Statements not in tail position run in <em>effect</em> mode (rebind the accumulators, produce no
    /// return); the last statement of the body runs in <em>tail</em> mode and produces the return —
    /// a <c>goto</c>/<c>halt</c>, a tail <c>if</c> whose branches each return, or a fall-through
    /// <c>{:keep_state, data}</c>. Constructs from later milestones (send, announce, new, loops,
    /// non-halt raise, function calls) emit a TODO marker and fall through.</para>
    /// </summary>
    internal sealed class ElixirFunctionEmitter
    {
        private readonly Machine machine;
        private readonly Function fn;
        private readonly ElixirTypeContext types;
        private readonly NameAllocator fields;
        private readonly NameAllocator locals = new NameAllocator();
        private readonly Variable paramVar;
        private readonly bool hasLocals;

        // Temporaries assigned an event reference, so a later `raise tmp` can be recognised as halt.
        private readonly Dictionary<Variable, Event> eventVars = new Dictionary<Variable, Event>();

        private string currentState;

        // Set once the body actually reads/writes/threads a local; gates emission of the `locals`
        // pre-seed and the payload binding, so handlers that never touch locals stay warning-free.
        private bool localsUsed;

        // Elixir variable the event/entry payload is bound to in the clause head.
        private const string PayloadVar = "payload";

        public ElixirFunctionEmitter(Machine machine, NameAllocator fields, Function fn, ElixirTypeContext types)
        {
            this.machine = machine;
            this.fields = fields;
            this.fn = fn;
            this.types = types;

            paramVar = fn.Signature.Parameters.FirstOrDefault();
            foreach (var p in fn.Signature.Parameters)
            {
                locals.Allocate(p);
            }

            foreach (var l in fn.LocalVariables)
            {
                locals.Allocate(l);
            }

            hasLocals = paramVar != null || fn.LocalVariables.Any();
        }

        /// <summary>
        /// Whether the rendered body uses the payload parameter (so the clause head must bind it
        /// rather than ignore it). Only meaningful after <see cref="Render"/>.
        /// </summary>
        public bool PayloadUsed => hasLocals && localsUsed && paramVar != null;

        /// <summary>
        /// Renders the handler body as the inner lines of a <c>handle_event/4</c> clause: the
        /// <c>locals</c> pre-seed (only if the body touches locals) followed by the statements.
        /// In tail mode the body produces the <c>:gen_statem</c> return; in effect mode it only
        /// rebinds the accumulators and the caller appends the transition (used for goto-with-fn).
        /// </summary>
        public string Render(string indent, bool tail, string stateName)
        {
            currentState = stateName;

            // Render the body first so `localsUsed` reflects what the statements actually need.
            var body = new StringBuilder();
            EmitBlock(body, fn.Body.Statements, indent, tail);

            var sb = new StringBuilder();
            if (hasLocals && localsUsed)
            {
                EmitLocalsInit(sb, indent);
            }

            sb.Append(body);
            return sb.ToString();
        }

        // Emits the `locals` map seeded with type-default values for every parameter and local, with
        // the payload parameter (if any) bound to the value matched in the clause head.
        private void EmitLocalsInit(StringBuilder sb, string indent)
        {
            var entries = new List<string>();
            foreach (var p in fn.Signature.Parameters)
            {
                entries.Add($"{locals[p]}: {(p == paramVar ? PayloadVar : types.Default(p.Type))}");
            }

            foreach (var l in fn.LocalVariables)
            {
                entries.Add($"{locals[l]}: {types.Default(l.Type)}");
            }

            Line(sb, indent, $"locals = %{{{string.Join(", ", entries)}}}");
        }

        // ---- statement emission -------------------------------------------------------------

        private void EmitBlock(StringBuilder sb, IReadOnlyList<IPStmt> stmts, string indent, bool tail)
        {
            if (stmts.Count == 0)
            {
                if (tail)
                {
                    Line(sb, indent, KeepReturn);
                }

                return;
            }

            for (var i = 0; i < stmts.Count; i++)
            {
                EmitStmt(sb, stmts[i], indent, tail && i == stmts.Count - 1);
            }
        }

        // Renders one statement atomically: if it needs an expression this milestone does not yet
        // support, the partial output is discarded and the whole statement degrades to a TODO marker,
        // so the surrounding handler still compiles and runs.
        private void EmitStmt(StringBuilder sb, IPStmt stmt, string indent, bool tail)
        {
            var scratch = new StringBuilder();
            try
            {
                EmitStmtInner(scratch, stmt, indent, tail);
                sb.Append(scratch);
            }
            catch (System.NotImplementedException)
            {
                Todo(sb, indent, "M3+", $"{stmt.GetType().Name} using an unsupported expression");
                if (tail)
                {
                    Line(sb, indent, KeepReturn);
                }
            }
        }

        private void EmitStmtInner(StringBuilder sb, IPStmt stmt, string indent, bool tail)
        {
            switch (stmt)
            {
                case CompoundStmt compound:
                    EmitBlock(sb, compound.Statements, indent, tail);
                    return;

                case NoStmt _:
                    if (tail)
                    {
                        Line(sb, indent, KeepReturn);
                    }

                    return;

                case GotoStmt gotoStmt:
                    EmitGoto(sb, indent, gotoStmt);
                    return;

                case RaiseStmt raiseStmt when ResolveEvent(raiseStmt.Event) is { IsHaltEvent: true }:
                    Line(sb, indent, $"PRuntime.halt(@p_machine, {ElixirNames.Atom(currentState)}, data)");
                    return;

                case IfStmt ifStmt:
                    if (tail)
                    {
                        EmitIfTail(sb, indent, ifStmt);
                    }
                    else
                    {
                        EmitIfEffect(sb, indent, ifStmt);
                    }

                    return;

                case AssignStmt assign:
                    EmitAssign(sb, indent, assign.Location, assign.Value);
                    break;

                case MoveAssignStmt move:
                    if (move.ToLocation is VariableAccessExpr dest && eventVars.TryGetValue(move.FromVariable, out var ev))
                    {
                        eventVars[dest.Variable] = ev;
                    }

                    Line(sb, indent, AssignTo(move.ToLocation, ReadVar(move.FromVariable)));
                    break;

                case AddStmt add:
                    Line(sb, indent, AssignTo(add.Variable, $"MapSet.put({EmitExpr(add.Variable)}, {EmitExpr(add.Value)})"));
                    break;

                case InsertStmt insert:
                    EmitInsert(sb, indent, insert);
                    break;

                case RemoveStmt remove:
                    EmitRemove(sb, indent, remove);
                    break;

                case PrintStmt print:
                    Line(sb, indent, $"IO.puts({EmitExpr(print.Message)})");
                    break;

                case AssertStmt assert:
                    Line(sb, indent, $"if !({EmitExpr(assert.Assertion)}), do: raise({EmitExpr(assert.Message)})");
                    break;

                // ---- deferred to later milestones: emit a marker and fall through ----------
                case SendStmt send:
                    Todo(sb, indent, "M3", $"send {EventName(send.Evt)} to another machine");
                    break;

                case CtorStmt _:
                    Todo(sb, indent, "M3", "new MachineName(...) (spawn under the DynamicSupervisor)");
                    break;

                case RaiseStmt raiseStmt:
                    Todo(sb, indent, "M4", $"raise {EventName(raiseStmt.Event)} (non-halt)");
                    break;

                case AnnounceStmt announce:
                    Todo(sb, indent, "M5", $"announce {EventName(announce.Event)}");
                    break;

                case WhileStmt _:
                case ForeachStmt _:
                case BreakStmt _:
                case ContinueStmt _:
                    Todo(sb, indent, "M4+", $"loop construct {stmt.GetType().Name}");
                    break;

                case FunCallStmt funCall:
                    Todo(sb, indent, "M6", $"call to P function {funCall.Function.Name}");
                    break;

                case ReturnStmt _:
                    Todo(sb, indent, "M6", "return from a P function");
                    break;

                case SwapAssignStmt _:
                    Todo(sb, indent, "M3+", "swap assignment");
                    break;

                default:
                    Todo(sb, indent, "M3+", $"unsupported statement {stmt.GetType().Name}");
                    break;
            }

            if (tail)
            {
                Line(sb, indent, KeepReturn);
            }
        }

        private void EmitGoto(StringBuilder sb, string indent, GotoStmt gotoStmt)
        {
            var payload = gotoStmt.Payload != null ? EmitExpr(gotoStmt.Payload) : "nil";
            Line(sb, indent,
                $"PRuntime.goto(@p_machine, {ElixirNames.Atom(currentState)}, {ElixirNames.Atom(gotoStmt.State.Name)}, data, {payload})");
        }

        private void EmitAssign(StringBuilder sb, string indent, IPExpr location, IPExpr value)
        {
            if (location is VariableAccessExpr target && Unwrap(value) is EventRefExpr eventRef)
            {
                // Track the binding so a later `raise tmp` resolves back to its event (e.g. halt).
                // When it is just an IR temporary feeding such a raise, the assignment itself is dead
                // — skip it so the handler stays clean (matches how `raise halt` lowers).
                eventVars[target.Variable] = eventRef.Value;
                if (target.Variable.Role.HasFlag(VariableRole.Temp))
                {
                    return;
                }
            }

            Line(sb, indent, AssignTo(location, EmitExpr(value)));
        }

        private void EmitInsert(StringBuilder sb, string indent, InsertStmt insert)
        {
            var coll = EmitExpr(insert.Variable);
            var updated = insert.Variable.Type.Canonicalize() is MapType
                ? $"Map.put({coll}, {EmitExpr(insert.Index)}, {EmitExpr(insert.Value)})"
                : $"List.insert_at({coll}, {EmitExpr(insert.Index)}, {EmitExpr(insert.Value)})";
            Line(sb, indent, AssignTo(insert.Variable, updated));
        }

        private void EmitRemove(StringBuilder sb, string indent, RemoveStmt remove)
        {
            var coll = EmitExpr(remove.Variable);
            var updated = remove.Variable.Type.Canonicalize() switch
            {
                MapType _ => $"Map.delete({coll}, {EmitExpr(remove.Value)})",
                SequenceType _ => $"List.delete_at({coll}, {EmitExpr(remove.Value)})",
                _ => $"MapSet.delete({coll}, {EmitExpr(remove.Value)})"
            };
            Line(sb, indent, AssignTo(remove.Variable, updated));
        }

        // An `if` in effect position rebinds the accumulators from the value of the `if` so that a
        // branch's mutations survive the merge. Both branches must return the same accumulator shape.
        private void EmitIfEffect(StringBuilder sb, string indent, IfStmt ifStmt)
        {
            var inner = indent + "    ";
            Line(sb, indent, $"{Accumulator} =");
            Line(sb, indent + "  ", $"if {EmitExpr(ifStmt.Condition)} do");
            EmitBlock(sb, ifStmt.ThenBranch.Statements, inner, tail: false);
            Line(sb, inner, Accumulator);
            Line(sb, indent + "  ", "else");
            if (ifStmt.ElseBranch != null)
            {
                EmitBlock(sb, ifStmt.ElseBranch.Statements, inner, tail: false);
            }

            Line(sb, inner, Accumulator);
            Line(sb, indent + "  ", "end");
        }

        // An `if` in tail position is the handler's return: each branch produces a :gen_statem return.
        private void EmitIfTail(StringBuilder sb, string indent, IfStmt ifStmt)
        {
            var inner = indent + "  ";
            Line(sb, indent, $"if {EmitExpr(ifStmt.Condition)} do");
            EmitBlock(sb, ifStmt.ThenBranch.Statements, inner, tail: true);
            Line(sb, indent, "else");
            if (ifStmt.ElseBranch != null && ifStmt.ElseBranch.Statements.Any())
            {
                EmitBlock(sb, ifStmt.ElseBranch.Statements, inner, tail: true);
            }
            else
            {
                Line(sb, inner, KeepReturn);
            }

            Line(sb, indent, "end");
        }

        // ---- lvalue (write) emission --------------------------------------------------------

        // Recursively rebuilds the root accumulator after a (possibly nested) lvalue write, e.g.
        // `m[k] = v` on field m becomes `data = %{data | m: Map.put(data.m, k, v)}`.
        private string AssignTo(IPExpr lvalue, string value)
        {
            switch (lvalue)
            {
                case VariableAccessExpr v:
                    if (IsField(v.Variable))
                    {
                        return $"data = %{{data | {fields[v.Variable]}: {value}}}";
                    }

                    localsUsed = true;
                    return $"locals = %{{locals | {locals[v.Variable]}: {value}}}";

                case MapAccessExpr m:
                    return AssignTo(m.MapExpr, $"Map.put({EmitExpr(m.MapExpr)}, {EmitExpr(m.IndexExpr)}, {value})");

                case SeqAccessExpr s:
                    return AssignTo(s.SeqExpr, $"List.replace_at({EmitExpr(s.SeqExpr)}, {EmitExpr(s.IndexExpr)}, {value})");

                case TupleAccessExpr t:
                    return AssignTo(t.SubExpr, $"put_elem({EmitExpr(t.SubExpr)}, {t.FieldNo}, {value})");

                case NamedTupleAccessExpr n:
                    return AssignTo(n.SubExpr, $"%{{{EmitExpr(n.SubExpr)} | {ElixirNames.FieldKey(n.FieldName)}: {value}}}");

                default:
                    return $"# TODO: unsupported lvalue {lvalue.GetType().Name}";
            }
        }

        // ---- expression (read) emission -----------------------------------------------------

        private string EmitExpr(IPExpr expr)
        {
            switch (expr)
            {
                case IntLiteralExpr i:
                    return i.Value.ToString();

                case FloatLiteralExpr f:
                    return ElixirTypeContext.FloatLiteral(f.Value);

                case BoolLiteralExpr b:
                    return b.Value ? "true" : "false";

                case NullLiteralExpr _:
                    return "nil";

                case EnumElemRefExpr e:
                    return ElixirNames.Atom(e.Value.Name);

                case EventRefExpr e:
                    return e.Value.IsHaltEvent ? ":halt" : ElixirNames.Atom(e.Value.Name);

                case VariableAccessExpr v:
                    return ReadVar(v.Variable);

                case ThisRefExpr _:
                    // P's `this` is the machine's own identity; on the BEAM that is its pid.
                    return "self()";

                case CloneExpr c:
                    return EmitExpr(c.Term);

                case CastExpr c:
                    return EmitExpr(c.SubExpr);

                case CoerceExpr c:
                    return EmitExpr(c.SubExpr);

                case DefaultExpr d:
                    return types.Default(d.Type);

                case UnaryOpExpr u:
                    return u.Operation == UnaryOpType.Negate ? $"(-{EmitExpr(u.SubExpr)})" : $"(not {EmitExpr(u.SubExpr)})";

                case BinOpExpr b:
                    return EmitBinOp(b);

                case SizeofExpr s:
                    return EmitSizeof(s);

                case KeysExpr k:
                    return $"Map.keys({EmitExpr(k.Expr)})";

                case ValuesExpr v:
                    return $"Map.values({EmitExpr(v.Expr)})";

                case ContainsExpr c:
                    return EmitContains(c);

                case MapAccessExpr m:
                    return $"Map.get({EmitExpr(m.MapExpr)}, {EmitExpr(m.IndexExpr)})";

                case SeqAccessExpr s:
                    return $"Enum.at({EmitExpr(s.SeqExpr)}, {EmitExpr(s.IndexExpr)})";

                case SetAccessExpr s:
                    return $"Enum.at(MapSet.to_list({EmitExpr(s.SetExpr)}), {EmitExpr(s.IndexExpr)})";

                case TupleAccessExpr t:
                    return $"elem({EmitExpr(t.SubExpr)}, {t.FieldNo})";

                case NamedTupleAccessExpr n:
                    return $"({EmitExpr(n.SubExpr)}).{ElixirNames.FieldKey(n.FieldName)}";

                case UnnamedTupleExpr t:
                    return "{" + string.Join(", ", t.TupleFields.Select(EmitExpr)) + "}";

                case NamedTupleExpr n:
                    return EmitNamedTuple(n);

                case SeqLiteralExpr s:
                    return "[" + string.Join(", ", s.Value.Select(EmitExpr)) + "]";

                case StringExpr s:
                    return EmitString(s);

                default:
                    // FunCall/Ctor/Choose/Nondet and friends arrive in later milestones.
                    throw new System.NotImplementedException(
                        $"Elixir backend (M2): expression {expr.GetType().Name} is not yet supported.");
            }
        }

        private string EmitBinOp(BinOpExpr b)
        {
            var l = EmitExpr(b.Lhs);
            var r = EmitExpr(b.Rhs);
            switch (b.Operation)
            {
                case BinOpType.Add: return $"({l} + {r})";
                case BinOpType.Sub: return $"({l} - {r})";
                case BinOpType.Mul: return $"({l} * {r})";
                // P int division truncates; Elixir `/` always yields a float, so use div/2 unless
                // the result type is float.
                case BinOpType.Div: return b.Type.IsSameTypeAs(PrimitiveType.Float) ? $"({l} / {r})" : $"div({l}, {r})";
                case BinOpType.Mod: return $"rem({l}, {r})";
                case BinOpType.Lt: return $"({l} < {r})";
                case BinOpType.Le: return $"({l} <= {r})";
                case BinOpType.Gt: return $"({l} > {r})";
                case BinOpType.Ge: return $"({l} >= {r})";
                case BinOpType.Eq: return $"({l} == {r})";
                case BinOpType.Neq: return $"({l} != {r})";
                case BinOpType.And: return $"({l} and {r})";
                case BinOpType.Or: return $"({l} or {r})";
                default:
                    throw new System.NotImplementedException($"Elixir backend (M2): operator {b.Operation} is not supported.");
            }
        }

        private string EmitSizeof(SizeofExpr s)
        {
            var x = EmitExpr(s.Expr);
            return s.Expr.Type.Canonicalize() switch
            {
                MapType _ => $"map_size({x})",
                SetType _ => $"MapSet.size({x})",
                _ => $"length({x})"
            };
        }

        private string EmitContains(ContainsExpr c)
        {
            var coll = EmitExpr(c.Collection);
            var item = EmitExpr(c.Item);
            return c.Collection.Type.Canonicalize() switch
            {
                MapType _ => $"Map.has_key?({coll}, {item})",
                SetType _ => $"MapSet.member?({coll}, {item})",
                _ => $"Enum.member?({coll}, {item})"
            };
        }

        private string EmitNamedTuple(NamedTupleExpr n)
        {
            var nt = (NamedTupleType)n.Type.Canonicalize();
            var fieldList = nt.Fields.ToList();
            var parts = fieldList
                .Select((f, i) => $"{ElixirNames.FieldKey(f.Name)}: {EmitExpr(n.TupleFields[i])}");
            return $"%{types.ModuleFor(nt)}{{{string.Join(", ", parts)}}}";
        }

        // P format strings use C#-style `{0}`,`{1}` placeholders; map them to Elixir interpolation,
        // escaping characters that would otherwise be special inside a double-quoted string.
        private string EmitString(StringExpr s)
        {
            var args = s.Args;
            var sb = new StringBuilder("\"");
            var src = s.BaseString;
            for (var i = 0; i < src.Length; i++)
            {
                var c = src[i];
                if (c == '{')
                {
                    var j = i + 1;
                    while (j < src.Length && char.IsDigit(src[j]))
                    {
                        j++;
                    }

                    if (j > i + 1 && j < src.Length && src[j] == '}'
                        && int.TryParse(src.Substring(i + 1, j - i - 1), out var idx) && idx < args.Count)
                    {
                        sb.Append("#{").Append(EmitExpr(args[idx])).Append('}');
                        i = j;
                        continue;
                    }
                }

                switch (c)
                {
                    case '\\': sb.Append("\\\\"); break;
                    case '"': sb.Append("\\\""); break;
                    case '#': sb.Append("\\#"); break;
                    default: sb.Append(c); break;
                }
            }

            sb.Append('"');
            return sb.ToString();
        }

        // ---- helpers ------------------------------------------------------------------------

        private static bool IsField(Variable v) => v.Role.HasFlag(VariableRole.Field);

        private string ReadVar(Variable v)
        {
            if (IsField(v))
            {
                return $"data.{fields[v]}";
            }

            localsUsed = true;
            return $"locals.{locals[v]}";
        }

        // The accumulator threaded through control flow: machine fields always, plus locals when the
        // handler has any parameters or locals (in which case the branch must carry them across).
        private string Accumulator
        {
            get
            {
                if (!hasLocals)
                {
                    return "data";
                }

                localsUsed = true;
                return "{data, locals}";
            }
        }

        private const string KeepReturn = "{:keep_state, data}";

        private Event ResolveEvent(IPExpr expr)
        {
            return Unwrap(expr) switch
            {
                EventRefExpr eventRef => eventRef.Value,
                VariableAccessExpr varAccess when eventVars.TryGetValue(varAccess.Variable, out var ev) => ev,
                _ => null
            };
        }

        // Best-effort event name for a TODO marker; falls back to a placeholder when the event is
        // only known dynamically.
        private string EventName(IPExpr expr) => ResolveEvent(expr)?.Name ?? "<event>";

        // A marker for a construct deferred to a later milestone: the handler still compiles and runs
        // (the statement is skipped), but the gap is visible in the generated source.
        private static void Todo(StringBuilder sb, string indent, string milestone, string what) =>
            Line(sb, indent, $"# TODO({milestone}): {what} — not yet generated by the Elixir backend");

        private static IPExpr Unwrap(IPExpr expr) => expr is CloneExpr clone ? clone.Term : expr;

        private static void Line(StringBuilder sb, string indent, string text) => sb.Append(indent).Append(text).Append('\n');
    }
}
