defmodule M1Harness.WalkerTest do
  @moduledoc """
  M1 walking-skeleton end-to-end test.

  Drives the generated `M1Demo.Walker` (compiled from `Walker.p`) and asserts the exact
  observable event trace: the machine is created, enters A, transitions A→B via the entry
  handler, enters B, dequeues event E, and halts. This proves the whole pipeline —
  P source → ElixirCodeGenerator → :gen_statem running on the BEAM → PRuntime trace.
  """
  use ExUnit.Case, async: false

  setup do
    PRuntime.Trace.reset()
    :ok
  end

  test "Walker walks A→B and halts on E, with the expected trace" do
    {:ok, sup} = M1Demo.Supervisor.start_link([])

    # The machine registers under its P name; fetch its pid.
    pid = wait_for_machine("Walker")

    # Wait until the machine has settled in B so the send is ordered after the transitions
    # (the internal entry events are processed before the cast either way, but this keeps the
    # *trace order* deterministic for an exact-match assertion).
    wait_until(fn -> {:enter, "Walker", :B} in PRuntime.Trace.entries() end)

    ref = Process.monitor(pid)
    PRuntime.send_event("test", pid, :E)

    # `raise halt` stops the machine normally; :transient means it is not restarted.
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    assert PRuntime.Trace.entries() == [
             {:create, "Walker"},
             {:enter, "Walker", :A},
             {:goto, "Walker", :A, :B},
             {:enter, "Walker", :B},
             {:send, "test", pid, :E},
             {:dequeue, "Walker", :B, :E},
             {:halt, "Walker", :B}
           ]

    Supervisor.stop(sup)
  end

  defp wait_for_machine(name, retries \\ 100) do
    case Registry.lookup(PRuntime.Registry, name) do
      [{pid, _}] -> pid
      [] when retries > 0 -> Process.sleep(5); wait_for_machine(name, retries - 1)
      [] -> flunk("machine #{name} never registered")
    end
  end

  defp wait_until(fun, retries \\ 100) do
    cond do
      fun.() -> :ok
      retries > 0 -> Process.sleep(5); wait_until(fun, retries - 1)
      true -> flunk("condition not met in time")
    end
  end
end
