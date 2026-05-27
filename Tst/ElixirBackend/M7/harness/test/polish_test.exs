ExUnit.start()

defmodule M7Harness.PolishTest do
  @moduledoc """
  M7 end-to-end test: the `any` type, and faithful failure surfacing.

  Drives the generated `M7Demo` program (compiled from `Polish.p`). A single `Vault` machine holds
  values of the `any` (top) type — across a scalar field, a `seq[any]` and a `map[string, any]` —
  and folds a stored `any` back into an int. The harness drives it directly, which keeps ordering
  deterministic (casts from one process to one `:gen_statem` are FIFO) and lets it poke the machine
  with events that exercise the two failure paths:

    - an event `Ready` does not handle (`eCheck`) now raises `PRuntime.UnhandledEvent` and records
      `{:unhandled, ...}`, instead of being silently dropped (M7 B1);
    - an unchecked `any`-to-int cast on a string value crashes, and the generated `terminate/3`
      records `{:crash, ...}` with machine/state context (M7 B2).

  `:sys.get_state` doubles as a synchronous mailbox flush: it cannot return until every preceding
  cast has been handled, so the asserted state reflects the whole driven sequence.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    PRuntime.Trace.reset()
    # Each test starts a Vault under the id "Vault"; a prior test's Vault is gone (halted/crashed),
    # but Registry deregistration on process death is asynchronous, so wait for the key to clear
    # before the next start_link to avoid an :already_started race.
    wait_until(fn -> Registry.lookup(PRuntime.Registry, "Vault") == [] end)
    :ok
  end

  test "the `any` type round-trips through a scalar, a seq and a map, and casts back to int" do
    {:ok, sup} = M7Demo.Supervisor.start_link([])
    vault = wait_for_machine("Vault")

    # default(any) is nil, alongside the other per-type defaults (proves the `any` field default).
    {:Ready, d0} = :sys.get_state(vault)
    assert d0.last == nil
    assert d0.items == []
    assert d0.m == %{}
    assert d0.total == 0
    assert d0.sawFive == false

    cast(vault, :eStore, 5)          # an int stored in an `any` field; `last == 5` sets sawFive
    cast(vault, :eSum)               # total = 0 + (last as int) = 5
    cast(vault, :eList, "hello")     # heterogeneous seq[any]: a string ...
    cast(vault, :eList, 42)          # ... then an int
    cast(vault, :eMap, %{k: "a", v: true})  # map[string, any] with a bool value
    cast(vault, :eStore, "world")    # the same `any` field now holds a string

    {:Ready, d} = :sys.get_state(vault)
    assert d.last == "world"
    assert d.items == ["hello", 42]
    assert d.m == %{"a" => true}
    assert d.total == 5
    assert d.sawFive == true

    # The trace records each dequeue against the single Ready state.
    entries = PRuntime.Trace.entries()
    assert {:dequeue, "Vault", :Ready, :eStore} in entries
    assert {:dequeue, "Vault", :Ready, :eSum} in entries
    assert {:dequeue, "Vault", :Ready, :eMap} in entries

    Supervisor.stop(sup)
  end

  test "an event the state does not handle raises PRuntime.UnhandledEvent and is recorded" do
    # Start the Vault standalone so the abnormal exit is contained here (a Supervisor would restart
    # the :transient child). It is linked to the test, so trap exits to keep that link from killing us.
    Process.flag(:trap_exit, true)
    {:ok, vault} = M7Demo.Vault.start_link(%{id: "Vault", args: nil})
    wait_until(fn -> {:enter, "Vault", :Ready} in PRuntime.Trace.entries() end)
    ref = Process.monitor(vault)

    log =
      capture_log(fn ->
        # eCheck is declared but unhandled in Ready: the generated catch-all routes it to
        # PRuntime.unhandled_event/3, which records, logs, and raises.
        :gen_statem.cast(vault, {:p_event, :eCheck, nil})
        assert_receive {:DOWN, ^ref, :process, ^vault, reason}, 1_000
        # The process exits because of the unhandled event, not normally.
        refute reason == :normal
        assert match?({%PRuntime.UnhandledEvent{event: :eCheck, state: :Ready}, _stack}, reason)
      end)

    assert {:unhandled, "Vault", :Ready, :eCheck} in PRuntime.Trace.entries()
    assert log =~ "unhandled event"
    refute Process.alive?(vault)
  end

  test "an abnormal crash is surfaced via terminate/3 as a {:crash, ...} trace entry" do
    Process.flag(:trap_exit, true)
    {:ok, vault} = M7Demo.Vault.start_link(%{id: "Vault", args: nil})
    wait_until(fn -> {:enter, "Vault", :Ready} in PRuntime.Trace.entries() end)
    ref = Process.monitor(vault)

    log =
      capture_log(fn ->
        # Store a string in the `any` field, then fold it as an int. The cast is an unchecked
        # pass-through (matching how the BEAM treats the term), so `0 + "boom"` raises an
        # ArithmeticError — an abnormal crash, distinct from a clean halt or a safety violation.
        :gen_statem.cast(vault, {:p_event, :eStore, "boom"})
        :gen_statem.cast(vault, {:p_event, :eSum, nil})
        assert_receive {:DOWN, ^ref, :process, ^vault, reason}, 1_000
        refute reason == :normal
      end)

    # terminate/3 routed the abnormal reason to PRuntime.terminated/3, which recorded the crash with
    # machine + state context and logged it (rather than letting it vanish into a bare gen_statem report).
    assert Enum.any?(PRuntime.Trace.entries(), &match?({:crash, "Vault", :Ready, _reason}, &1))
    assert log =~ "crashed"
    refute Process.alive?(vault)
  end

  # Cast a P event to the machine exactly as PRuntime.send_event would deliver it.
  defp cast(pid, event, payload \\ nil), do: :gen_statem.cast(pid, {:p_event, event, payload})

  defp wait_until(fun, retries \\ 200) do
    cond do
      fun.() -> :ok
      retries > 0 -> Process.sleep(5); wait_until(fun, retries - 1)
      true -> flunk("condition not met in time")
    end
  end

  defp wait_for_machine(name, retries \\ 100) do
    case Registry.lookup(PRuntime.Registry, name) do
      [{pid, _}] -> pid
      [] when retries > 0 -> Process.sleep(5); wait_for_machine(name, retries - 1)
      [] -> flunk("machine #{name} never registered")
    end
  end
end
