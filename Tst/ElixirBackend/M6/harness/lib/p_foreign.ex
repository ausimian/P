defmodule PForeign do
  @moduledoc """
  Hand-written foreign bindings for the generated `M6Demo` program.

  This is the host-supplied module the generated `FOREIGN.md` asks for: it implements every P
  `foreign` function the generated code calls as `PForeign.<name>(args)`. The compiler emits a
  stub of exactly this shape; here it is filled in for the test.

  `Accumulator` is a P *foreign type* — opaque to the generated code, which only passes values of
  it between these functions. We are free to pick any Elixir representation; we use a plain list of
  the folded ints. The choice is invisible to the P program.
  """

  @doc "Construct an empty accumulator (the opaque P `Accumulator`)."
  def newAccumulator(), do: []

  @doc "Fold `value` into `acc`, returning the new accumulator."
  def accumulate(acc, value), do: [value | acc]

  @doc "Collapse the accumulator to an int. (Sum * 2, so the foreign computation is observable.)"
  def digest(acc), do: Enum.sum(acc) * 2

  @doc "Side-effect-only hook (the generated code calls this as a statement and discards the result)."
  def noteValue(_value), do: :ok
end
