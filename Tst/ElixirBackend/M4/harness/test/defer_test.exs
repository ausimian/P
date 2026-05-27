ExUnit.start()

defmodule M4Harness.DeferTest do
  @moduledoc """
  M4 end-to-end test: defer, ignore, and (non-halt) raise.

  Drives the generated `M4Demo.Worker` (compiled from `Defer.p`). The Worker starts in
  `Buffering`, where it *defers* `eWork`, *ignores* `eNoise`, and moves to `Draining` on
  `eFlush`. `Draining` handles `eWork`; `eGo` *raises* `eDone`, which halts the machine.

  The point is the deferral round-trip: `eWork` events sent while in `Buffering` must NOT be
  handled there, but must be re-delivered — in order — once the machine reaches `Draining`,
  which sums their payloads. The trace makes the ordering observable: no `eWork` dequeue in
  Buffering, two `eWork` dequeues in Draining, and a `defer` entry per buffered event.
  """
  use ExUnit.Case, async: false

  setup do
    PRuntime.Trace.reset()
    :ok
  end

  test "Worker defers eWork in Buffering, re-delivers it in Draining, ignores eNoise, raises eDone" do
    {:ok, sup} = M4Demo.Supervisor.start_link([])
    pid = wait_for_machine("Worker")

    wait_until(fn -> {:enter, "Worker", :Buffering} in PRuntime.Trace.entries() end)

    # Everything below is sent from this single process, so the casts arrive FIFO. In Buffering:
    # the two eWork are deferred, eNoise is ignored, eFlush transitions to Draining. The deferred
    # eWork events are then re-delivered (front of queue, in order) and handled in Draining.
    PRuntime.send_event("test", pid, :eWork, 10)
    PRuntime.send_event("test", pid, :eNoise)
    PRuntime.send_event("test", pid, :eWork, 5)
    PRuntime.send_event("test", pid, :eFlush)

    # Both deferred eWork events are summed once the machine drains them.
    wait_until(fn -> elem(:sys.get_state(pid), 1).count == 2 end)

    {state, data} = :sys.get_state(pid)
    assert state == :Draining
    assert data.handled == 15
    assert data.count == 2

    entries = PRuntime.Trace.entries()

    # eWork was deferred (not handled) in Buffering...
    assert count(entries, {:defer, "Worker", :Buffering, :eWork}) == 2
    refute Enum.any?(entries, &match?({:dequeue, "Worker", :Buffering, :eWork}, &1))

    # ...and re-delivered + handled in Draining, in order (10 before 5: handled climbed 10 -> 15).
    assert count(entries, {:dequeue, "Worker", :Draining, :eWork}) == 2

    # eNoise was ignored, never handled.
    assert {:ignore, "Worker", :Buffering, :eNoise} in entries
    refute Enum.any?(entries, &match?({:dequeue, _, _, :eNoise}, &1))

    # eFlush drove the transition.
    assert {:goto, "Worker", :Buffering, :Draining} in entries

    # Non-halt raise: eGo raises eDone, which is then dequeued and halts the machine.
    ref = Process.monitor(pid)
    PRuntime.send_event("test", pid, :eGo)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

    entries = PRuntime.Trace.entries()
    assert {:dequeue, "Worker", :Draining, :eGo} in entries
    assert {:raise, "Worker", :Draining, :eDone} in entries
    assert {:dequeue, "Worker", :Draining, :eDone} in entries
    assert {:halt, "Worker", :Draining} in entries

    # The raised eDone is processed ahead of anything else and before the halt: its dequeue
    # immediately follows the eGo dequeue, with nothing handled in between.
    go_idx = Enum.find_index(entries, &(&1 == {:dequeue, "Worker", :Draining, :eGo}))
    done_idx = Enum.find_index(entries, &(&1 == {:dequeue, "Worker", :Draining, :eDone}))
    assert done_idx == go_idx + 2, "expected eGo dequeue, then its raise, then eDone dequeue"
    assert Enum.at(entries, go_idx + 1) == {:raise, "Worker", :Draining, :eDone}

    Supervisor.stop(sup)
  end

  defp count(entries, entry), do: Enum.count(entries, &(&1 == entry))

  defp wait_for_machine(name, retries \\ 100) do
    case Registry.lookup(PRuntime.Registry, name) do
      [{pid, _}] -> pid
      [] when retries > 0 -> Process.sleep(5); wait_for_machine(name, retries - 1)
      [] -> flunk("machine #{name} never registered")
    end
  end

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> :ok
      retries > 0 -> Process.sleep(5); wait_until(fun, retries - 1)
      true -> flunk("condition not met in time")
    end
  end
end
