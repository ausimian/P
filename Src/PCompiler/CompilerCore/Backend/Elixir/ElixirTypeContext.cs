using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using Plang.Compiler.TypeChecker;
using Plang.Compiler.TypeChecker.AST.Declarations;
using Plang.Compiler.TypeChecker.Types;

namespace Plang.Compiler.Backend.Elixir
{
    /// <summary>
    /// Owns the P-type → Elixir-term mapping for a single generated program (M2: payloads and the
    /// type system).
    ///
    /// P's named tuples are <em>structural</em> (anonymous), so two declarations with identical
    /// field names and types are the same type. We therefore dedupe shapes by their canonical
    /// representation and emit one <c>defstruct</c> module per distinct shape, named
    /// <c>&lt;Prefix&gt;.Types.T0</c>, <c>T1</c>, … in discovery order. Construction sites look the
    /// module up by canonical representation; field <em>reads</em> (<c>t.field</c>) work on any map
    /// or struct and don't need the module name.
    ///
    /// Everything else maps directly onto built-in Elixir terms (see <see cref="Default"/> and the
    /// emitter), so no per-type code generation is required for them.
    /// </summary>
    internal sealed class ElixirTypeContext
    {
        private readonly string modulePrefix;
        private readonly Dictionary<string, string> shapeToSimpleName = new Dictionary<string, string>();
        private readonly List<NamedTupleType> shapes = new List<NamedTupleType>();

        public ElixirTypeContext(string modulePrefix)
        {
            this.modulePrefix = modulePrefix;
        }

        /// <summary>Whether any named-tuple struct modules were discovered (i.e. a types file is needed).</summary>
        public bool HasNamedTuples => shapes.Count > 0;

        /// <summary>
        /// Walks the whole program and records every named-tuple shape reachable from a declaration,
        /// so a struct module exists for each before any code that constructs or defaults one is emitted.
        /// </summary>
        public void CollectFrom(Scope globalScope)
        {
            foreach (var ev in globalScope.AllDecls.OfType<Event>())
            {
                Collect(ev.PayloadType);
            }

            foreach (var machine in globalScope.Machines)
            {
                if (machine.PayloadType != null)
                {
                    Collect(machine.PayloadType);
                }

                foreach (var field in machine.Fields)
                {
                    Collect(field.Type);
                }

                foreach (var method in machine.Methods)
                {
                    CollectFromFunction(method);
                }
            }

            foreach (var fn in globalScope.GetAllMethods())
            {
                CollectFromFunction(fn);
            }
        }

        private void CollectFromFunction(Function fn)
        {
            Collect(fn.Signature.ReturnType);
            foreach (var p in fn.Signature.Parameters)
            {
                Collect(p.Type);
            }

            foreach (var local in fn.LocalVariables)
            {
                Collect(local.Type);
            }
        }

        /// <summary>Recursively registers any named-tuple shapes nested inside <paramref name="type"/>.</summary>
        private void Collect(PLanguageType type)
        {
            switch (type?.Canonicalize())
            {
                case NamedTupleType nt:
                    foreach (var f in nt.Fields)
                    {
                        Collect(f.Type);
                    }

                    Register(nt);
                    break;

                case TupleType tt:
                    foreach (var t in tt.Types)
                    {
                        Collect(t);
                    }

                    break;

                case SequenceType seq:
                    Collect(seq.ElementType);
                    break;

                case SetType set:
                    Collect(set.ElementType);
                    break;

                case MapType map:
                    Collect(map.KeyType);
                    Collect(map.ValueType);
                    break;
            }
        }

        private string Register(NamedTupleType nt)
        {
            var key = nt.CanonicalRepresentation;
            if (!shapeToSimpleName.TryGetValue(key, out var simple))
            {
                simple = $"T{shapes.Count}";
                shapeToSimpleName[key] = simple;
                shapes.Add(nt);
            }

            return simple;
        }

        /// <summary>Fully-qualified Elixir module alias for a named-tuple shape (e.g. <c>MyApp.Types.T0</c>).</summary>
        public string ModuleFor(NamedTupleType nt)
        {
            // Collection runs before emission, so every shape is registered; Register is idempotent.
            return $"{modulePrefix}.Types.{Register(nt)}";
        }

        /// <summary>
        /// The Elixir term that a freshly-declared value of <paramref name="type"/> holds, matching
        /// P's per-type default (0, 0.0, false, "", [], empty set/map, all-default tuples/structs,
        /// the lowest-valued enum element, nil for machine/event/any).
        /// </summary>
        public string Default(PLanguageType type)
        {
            switch (type.Canonicalize())
            {
                case EnumType enumType:
                    var min = enumType.EnumDecl.Values.OrderBy(e => e.Value).First();
                    return $":\"{min.Name}\"";

                case SequenceType _:
                    return "[]";

                case SetType _:
                    return "MapSet.new()";

                case MapType _:
                    return "%{}";

                case NamedTupleType nt:
                    return $"%{ModuleFor(nt)}{{}}";

                case TupleType tt:
                    return "{" + string.Join(", ", tt.Types.Select(Default)) + "}";

                case PrimitiveType p when p.IsSameTypeAs(PrimitiveType.Bool):
                    return "false";

                case PrimitiveType p when p.IsSameTypeAs(PrimitiveType.Int):
                    return "0";

                case PrimitiveType p when p.IsSameTypeAs(PrimitiveType.Float):
                    return "0.0";

                case PrimitiveType p when p.IsSameTypeAs(PrimitiveType.String):
                    return "\"\"";

                default:
                    // machine, event, any, null, data, foreign — no zero value on the BEAM, so nil.
                    // For `any` (M7) this is the whole story: an `any` value is an opaque BEAM term,
                    // so it needs no per-type mapping — it is constructed, compared, passed and cast
                    // through the same emitter paths as its concrete underlying value.
                    return "nil";
            }
        }

        /// <summary>
        /// Emits <c>lib/&lt;app&gt;/types.ex</c> declaring one <c>defstruct</c> module per named-tuple
        /// shape, or null when the program uses none. Field defaults reference other shapes' modules,
        /// which is fine because Elixir resolves module aliases regardless of definition order.
        /// </summary>
        public CompiledFile EmitTypesFile(string appName)
        {
            if (!HasNamedTuples)
            {
                return null;
            }

            var sb = new StringBuilder();
            sb.Append(
$@"# Struct modules for the program's named-tuple shapes (one per distinct shape).
# Generated by the P compiler's Elixir backend. Do not edit.
");
            foreach (var nt in shapes)
            {
                var fields = string.Join(", ",
                    nt.Fields.Select(f => $"{ElixirNames.FieldKey(f.Name)}: {Default(f.Type)}"));
                sb.Append($"\ndefmodule {ModuleFor(nt)} do\n");
                sb.Append($"  @moduledoc \"P named tuple ({nt.CanonicalRepresentation}).\"\n");
                sb.Append($"  defstruct [{fields}]\n");
                sb.Append("end\n");
            }

            var file = new CompiledFile(Path.Combine("lib", appName, "types.ex"));
            file.Stream.Write(sb.ToString());
            return file;
        }

        /// <summary>Formats a P float literal so it is always a valid Elixir float (e.g. <c>5</c> → <c>5.0</c>).</summary>
        public static string FloatLiteral(double value)
        {
            var s = value.ToString("R", CultureInfo.InvariantCulture);
            if (!s.Contains('.') && !s.Contains('e') && !s.Contains('E'))
            {
                s += ".0";
            }

            return s;
        }
    }
}
