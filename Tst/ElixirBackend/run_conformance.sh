#!/usr/bin/env bash
#
# Conformance suite for the P -> Elixir backend.
#
# For each milestone fixture under Tst/ElixirBackend/M*, compiles the .p program with
# `--mode elixir` and runs its ExUnit harness. The harnesses encode hand-verified expected
# observable traces, so a green run is the conformance assertion that the generated program
# behaves as the P semantics require (DESIGN.md M7). There is no C backend and PChecker is a model
# checker rather than a single-trace executor, so live cross-backend trace diffing is out of scope.
#
# Usage:
#   Tst/ElixirBackend/run_conformance.sh [M1 M2 ...]
#
# With no arguments, runs every M* fixture in order. Environment:
#   P_CMD   how to invoke the P compiler (default: the Debug build's p.dll via dotnet).
#           e.g. P_CMD="p" to use an installed global tool.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../.." && pwd)"

# Default to the Debug drop; fall back to Release. DOTNET_ROLL_FORWARD lets the net8.0 binary run
# on a newer installed runtime (e.g. .NET 9) without a separate net8 install.
if [[ -z "${P_CMD:-}" ]]; then
  dll="$repo_root/Bld/Drops/Debug/Binaries/net8.0/p.dll"
  [[ -f "$dll" ]] || dll="$repo_root/Bld/Drops/Release/Binaries/net8.0/p.dll"
  if [[ ! -f "$dll" ]]; then
    echo "error: no built p.dll found; run ./Bld/build.sh first or set P_CMD" >&2
    exit 1
  fi
  export DOTNET_ROLL_FORWARD="${DOTNET_ROLL_FORWARD:-Major}"
  P_CMD="dotnet $dll"
fi

# Milestones to run: explicit args, or every M<N> directory in numeric order. Avoid `mapfile`
# (absent from the bash 3.2 that ships on macOS) so the script runs the same locally and in CI.
if [[ $# -gt 0 ]]; then
  milestones=("$@")
else
  milestones=()
  while IFS= read -r m; do
    milestones+=("$m")
  done < <(find "$here" -maxdepth 1 -type d -name 'M[0-9]*' -exec basename {} \; | sort -V)
fi

echo "P compiler: $P_CMD"
echo "Milestones: ${milestones[*]}"

for m in "${milestones[@]}"; do
  dir="$here/$m"
  [[ -d "$dir" ]] || { echo "skip $m (no such fixture)"; continue; }
  echo
  echo "==================== $m ===================="

  echo "--- compiling ($m) ---"
  ( cd "$dir" && $P_CMD compile --mode elixir )

  echo "--- mix test ($m) ---"
  ( cd "$dir/harness" && mix deps.get && mix test )
done

echo
echo "All conformance milestones passed: ${milestones[*]}"
