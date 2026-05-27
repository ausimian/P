defmodule M6Harness.ForeignTest do
  @moduledoc """
  M6 end-to-end test: foreign types and foreign functions.

  Drives the generated `M6Demo` program (compiled from `Foreign.p`). `Main` builds an opaque
  `Accumulator` via the host's `PForeign` module, folds three ints into it (`eAdd`), then digests
  it to an int (`eDigest`) and parks in `Done`. The whole point is that the generated code never
  inspects the `Accumulator` — it only routes it between `PForeign` calls — so the host alone
  decides its representation (here, a list) and its arithmetic (sum * 2).

  The test reads the resulting `result` field and the opaque `acc` field via `:sys.get_state`,
  proving the foreign value flowed through the generated code untouched, and confirms `noteValue`
  (a void foreign call in statement position) is reachable without affecting the state.
  """
  use ExUnit.Case, async: false

  setup do
    PRuntime.Trace.reset()
    :ok
  end

  test "Main folds values through foreign calls and digests the opaque accumulator" do
    {:ok, sup} = M6Demo.Supervisor.start_link([])
    main = wait_for_machine("Main")

    # The entry handler ran `acc = newAccumulator()` and transitioned to Counting.
    assert {state, _data} = :sys.get_state(main)
    assert state == :Counting

    # Fold three values in. Each eAdd calls noteValue/1 (void, statement) then accumulate/2 (value).
    :gen_statem.cast(main, {:p_event, :eAdd, 3})
    :gen_statem.cast(main, {:p_event, :eAdd, 4})
    :gen_statem.cast(main, {:p_event, :eAdd, 5})
    :gen_statem.cast(main, {:p_event, :eDigest, nil})

    # :sys.get_state flushes the mailbox (FIFO), so all four casts are handled before it returns.
    {state, data} = :sys.get_state(main)

    # digest([5,4,3]) = (5+4+3) * 2 = 24 — the foreign computation ran end to end.
    assert state == :Done
    assert data.result == 24

    # The opaque Accumulator flowed through the generated code untouched: it holds exactly what the
    # host's accumulate/2 built (a list, the representation P never sees), most-recent-first.
    assert data.acc == [5, 4, 3]

    entries = PRuntime.Trace.entries()
    assert {:enter, "Main", :Counting} in entries
    assert {:dequeue, "Main", :Counting, :eAdd} in entries
    assert {:dequeue, "Main", :Counting, :eDigest} in entries
    assert {:enter, "Main", :Done} in entries

    Supervisor.stop(sup)
  end

  defp wait_for_machine(name, retries \\ 100) do
    case Registry.lookup(PRuntime.Registry, name) do
      [{pid, _}] -> pid
      [] when retries > 0 -> Process.sleep(5); wait_for_machine(name, retries - 1)
      [] -> flunk("machine #{name} never registered")
    end
  end
end
