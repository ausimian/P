defmodule M2Harness.StoreTest do
  @moduledoc """
  M2 end-to-end test: payloads and the type system.

  Drives the generated `M2Demo.Store` (compiled from `Store.p`) with events carrying int,
  named-tuple and anonymous-named-tuple payloads, then asserts the resulting machine state —
  proving that payloads are bound and threaded, machine fields persist across handlers, and
  seq/set/map plus named-tuple structs round-trip through `:gen_statem`.
  """
  use ExUnit.Case, async: false

  alias M2Demo.Types.{T0, T1}

  setup do
    PRuntime.Trace.reset()
    :ok
  end

  test "Store accumulates typed payloads into fields, then halts" do
    {:ok, sup} = M2Demo.Supervisor.start_link([])
    pid = wait_for_machine("Store")

    # Entry runs in Init and immediately transitions to Running.
    wait_until(fn -> {:enter, "Store", :Running} in PRuntime.Trace.entries() end)

    PRuntime.send_event("test", pid, :eAdd, 5)
    PRuntime.send_event("test", pid, :eAdd, 12)
    PRuntime.send_event("test", pid, :eItem, %T0{id: 1, qty: 7})
    PRuntime.send_event("test", pid, :ePut, %T1{key: 9, val: 99})
    PRuntime.send_event("test", pid, :eAdd, 3)

    # Wait until all five are processed (total reflects 5 + 12 + 7 + 3).
    wait_until(fn -> elem(:sys.get_state(pid), 1).total == 27 end)

    {state, data} = :sys.get_state(pid)
    assert state == :Running
    assert data.total == 27
    assert data.nums == [5, 12, 3]
    assert data.seen == MapSet.new([5, 12, 3])
    assert data.prices == %{9 => 99}
    assert data.lastItem == %T0{id: 1, qty: 7}
    assert data.bigCount == 1

    ref = Process.monitor(pid)
    PRuntime.send_event("test", pid, :eDone)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    # The startup prefix is deterministic (it precedes any send); the halt is the final milestone.
    assert Enum.take(PRuntime.Trace.entries(), 4) == [
             {:create, "Store"},
             {:enter, "Store", :Init},
             {:goto, "Store", :Init, :Running},
             {:enter, "Store", :Running}
           ]

    assert {:halt, "Store", :Running} in PRuntime.Trace.entries()

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
