defmodule M3Harness.PingPongTest do
  @moduledoc """
  M3 end-to-end test: multiple machines, dynamic creation, and cross-machine sends.

  Drives the generated `M3Demo` program (compiled from `PingPong.p`). Starting the supervisor
  starts only the root machine `Main`, whose entry creates a `Ponger` and a `Pinger` with `new`.
  The Pinger pings the Ponger (passing `this` so the Ponger can reply), bounces three times, then
  halts. This proves the M3 pipeline: `new` spawning under the DynamicSupervisor, opaque machine
  ids in the registry, and sends resolved by id — including a machine sending to one it was handed
  as a payload.

  Cross-machine ordering is asynchronous, so the assertions check per-machine causal facts
  (how many pings/pongs each side handled) rather than a single global interleaving.
  """
  use ExUnit.Case, async: false

  setup do
    PRuntime.Trace.reset()
    :ok
  end

  test "Main creates a Pinger and Ponger; they bounce 3 times, then the Pinger halts" do
    {:ok, sup} = M3Demo.Supervisor.start_link([])

    # The Pinger halts after its third pong; wait for that, then for its registry entry to clear.
    wait_until(fn -> {:halt, "Pinger", :Pinging} in PRuntime.Trace.entries() end)
    wait_until(fn -> Registry.lookup(PRuntime.Registry, "Pinger") == [] end)

    entries = PRuntime.Trace.entries()

    # Creation order is deterministic: the supervisor starts Main, whose entry creates the Ponger
    # then the Pinger (both synchronously, via PRuntime.Spawner, before any ping is sent).
    assert Enum.filter(entries, &match?({:create, _}, &1)) ==
             [{:create, "Main"}, {:create, "Ponger"}, {:create, "Pinger"}]

    # Three full round-trips: Pinger enters Pinging and pings 3 times; Ponger handles 3 pings and
    # replies 3 pongs; Pinger handles 3 pongs.
    assert count(entries, {:enter, "Pinger", :Pinging}) == 3
    assert count(entries, {:send, "Pinger", "Ponger", :ePing}) == 3
    assert count(entries, {:dequeue, "Ponger", :Wait, :ePing}) == 3
    assert count(entries, {:send, "Ponger", "Pinger", :ePong}) == 3
    assert count(entries, {:dequeue, "Pinger", :Pinging, :ePong}) == 3
    assert {:halt, "Pinger", :Pinging} in entries

    # The transient Pinger is gone; the Ponger and Main remain registered by their ids.
    assert Registry.lookup(PRuntime.Registry, "Pinger") == []
    assert [{_pid, _}] = Registry.lookup(PRuntime.Registry, "Ponger")
    assert [{_pid, _}] = Registry.lookup(PRuntime.Registry, "Main")

    Supervisor.stop(sup)
  end

  defp count(entries, entry), do: Enum.count(entries, &(&1 == entry))

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> :ok
      retries > 0 -> Process.sleep(5); wait_until(fun, retries - 1)
      true -> flunk("condition not met in time")
    end
  end
end
