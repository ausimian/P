using System.Collections.Generic;
using System.Linq;
using System.Text;
using Plang.Compiler.TypeChecker.AST.Declarations;

namespace Plang.Compiler.Backend.Elixir
{
    /// <summary>
    /// Name-sanitization helpers shared across the Elixir backend.
    ///
    /// P identifiers (machine/state/event names, variables, tuple fields) are broader than Elixir's
    /// and the IR adds temporaries like <c>$tmp0</c> whose characters are illegal in Elixir. These
    /// helpers map any P name onto a valid Elixir token, and <see cref="NameAllocator"/> guarantees
    /// distinct P variables never collapse to the same Elixir variable within one function.
    /// </summary>
    internal static class ElixirNames
    {
        // Words that are illegal or unsafe as Elixir variable / map-key identifiers.
        private static readonly HashSet<string> Reserved = new HashSet<string>
        {
            "true", "false", "nil", "when", "and", "or", "not", "in", "fn", "do", "end", "catch",
            "rescue", "after", "else", "if", "unless", "case", "cond", "for", "with", "def", "defp",
            "defmodule", "defstruct", "import", "require", "use", "alias", "receive", "try", "raise",
            "quote", "unquote", "super", "data", "locals"
        };

        /// <summary>
        /// A valid Elixir variable / map-key identifier derived from a P name: illegal characters
        /// become <c>_</c>, the result is forced to start with a lowercase letter (so it is legal
        /// both as <c>name:</c> keyword keys and <c>x.name</c> access), and reserved words are
        /// suffixed with <c>_</c>.
        /// </summary>
        public static string Identifier(string name)
        {
            var sb = new StringBuilder();
            foreach (var c in name)
            {
                sb.Append((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
                    ? c
                    : '_');
            }

            if (sb.Length == 0 || !(sb[0] >= 'a' && sb[0] <= 'z'))
            {
                sb.Insert(0, 'v');
            }

            var result = sb.ToString();
            return Reserved.Contains(result) ? result + "_" : result;
        }

        /// <summary>Struct / map field key for a P (named-tuple or machine field) name.</summary>
        public static string FieldKey(string name) => Identifier(name);

        // P state/event names that are already valid bare atoms (letters/digits/underscores starting
        // with a letter or underscore) need no quoting; anything else is quoted to stay valid.
        private static readonly System.Text.RegularExpressions.Regex BareAtom =
            new System.Text.RegularExpressions.Regex("^[A-Za-z_][A-Za-z0-9_]*[?!]?$");

        /// <summary>An Elixir atom literal for a P name (e.g. <c>:Init</c>, or <c>:"odd-name"</c> when quoting is needed).</summary>
        public static string Atom(string name) => BareAtom.IsMatch(name) ? $":{name}" : $":\"{name}\"";
    }

    /// <summary>
    /// Allocates unique Elixir identifiers for a set of P <see cref="Variable"/>s (a function's
    /// parameters and locals, or a machine's fields), so two P names that sanitize to the same token
    /// get distinct Elixir names.
    /// </summary>
    internal sealed class NameAllocator
    {
        private readonly Dictionary<Variable, string> names = new Dictionary<Variable, string>();
        private readonly HashSet<string> used = new HashSet<string>();

        public string this[Variable v] => names[v];

        public bool Contains(Variable v) => names.ContainsKey(v);

        public string Allocate(Variable v)
        {
            if (names.TryGetValue(v, out var existing))
            {
                return existing;
            }

            var baseName = ElixirNames.Identifier(v.Name);
            var name = baseName;
            var i = 1;
            while (!used.Add(name))
            {
                name = $"{baseName}_{i++}";
            }

            names[v] = name;
            return name;
        }

        public IEnumerable<Variable> Variables => names.Keys;
    }
}
