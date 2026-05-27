ExUnit.start()

defmodule M5Harness.ReqRespTest do
  @moduledoc """
  M5 end-to-end test: spec monitors, event fan-out, and `announce`.

  Drives the generated `M5Demo` program (compiled from `ReqResp.p`). `Main` creates a `Server`
  and sends it `eReq` (carrying `this`); the `Server` `announce`s `eObserved` and replies `eResp`;
  `Main` halts on the reply. The `Watcher` spec — a separate `:gen_statem` process started by the
  supervisor before any machine — observes `eReq`, `eResp` and `eObserved` without ever sending or
  creating, and asserts the safety property `resps <= reqs`.

  The point is the fan-out: the spec is an independent process, yet it observes every relevant
  event mirrored to it synchronously at send/announce time. The trace makes this observable (the
  spec dequeues each observed event) and `:sys.get_state` on the spec confirms its accumulated
  counts and the announced value it received.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  setup do
    # Monitoring is opt-in (the `:p_runtime, :monitoring` flag). Reset to the production default
    # (off) before each test; tests that want the fan-out enable it explicitly.
    Application.delete_env(:p_runtime, :monitoring)
    on_exit(fn -> Application.delete_env(:p_runtime, :monitoring) end)
    PRuntime.Trace.reset()
    :ok
  end

  test "Watcher observes the request/response handshake and the announced value" do
    # Acceptance/conformance configuration: monitoring on, so the Watcher is fed observed events.
    Application.put_env(:p_runtime, :monitoring, true)

    {:ok, sup} = M5Demo.Supervisor.start_link([])

    watcher = wait_for_machine("Watcher")
    main = wait_for_machine("Main")

    # Main halts once it receives eResp; wait for that to settle the whole exchange.
    ref = Process.monitor(main)
    assert_receive {:DOWN, ^ref, :process, ^main, :normal}, 1_000

    # The spec observed exactly one request and one response, with the safety assertion holding,
    # and received the announced value (99) — proving announce fan-out reached the monitor.
    {state, data} = :sys.get_state(watcher)
    assert state == :Watching
    assert data.reqs == 1
    assert data.resps == 1
    assert data.lastAnnounced == 99

    entries = PRuntime.Trace.entries()

    # The spec is its own process: it entered its start state and dequeued each observed event.
    assert {:enter, "Watcher", :Watching} in entries
    assert {:dequeue, "Watcher", :Watching, :eReq} in entries
    assert {:dequeue, "Watcher", :Watching, :eResp} in entries
    assert {:dequeue, "Watcher", :Watching, :eObserved} in entries

    # announce was recorded, and the Server's send/Main's send drove the handshake.
    assert {:announce, "Server", :eObserved} in entries
    assert {:send, "Main", "Server", :eReq} in entries
    assert {:send, "Server", "Main", :eResp} in entries

    # Fan-out happens at send time, before the target dequeues: the spec observes eReq (mirrored
    # from Main's send) before the Server itself dequeues eReq.
    watcher_req = index(entries, {:dequeue, "Watcher", :Watching, :eReq})
    server_req = index(entries, {:dequeue, "Server", :Up, :eReq})
    assert watcher_req < server_req,
           "spec should observe eReq at send time, before the Server dequeues it"

    # Likewise the spec observes eResp before Main dequeues it.
    watcher_resp = index(entries, {:dequeue, "Watcher", :Watching, :eResp})
    main_resp = index(entries, {:dequeue, "Main", :Init, :eResp})
    assert watcher_resp < main_resp,
           "spec should observe eResp at send time, before Main dequeues it"

    Supervisor.stop(sup)
  end

  test "with monitoring off the spec is instantiated but starved, and the machines still run" do
    # Production configuration: monitoring stays off (the setup default). The Watcher process is
    # still started and registered by the supervisor — it is just never fed events.
    refute PRuntime.Specs.enabled?()

    {:ok, sup} = M5Demo.Supervisor.start_link([])

    watcher = wait_for_machine("Watcher")
    main = wait_for_machine("Main")

    # The system runs to completion exactly as before: Main still gets its reply and halts.
    ref = Process.monitor(main)
    assert_receive {:DOWN, ^ref, :process, ^main, :normal}, 1_000

    # The spec exists and reached its start state, but observed nothing — no fan-out occurred.
    {state, data} = :sys.get_state(watcher)
    assert state == :Watching
    assert data.reqs == 0
    assert data.resps == 0
    assert data.lastAnnounced == 0

    entries = PRuntime.Trace.entries()
    # The machine-level send/announce trace is still recorded (logging is independent of
    # monitoring), but the Watcher never dequeued anything.
    assert {:send, "Main", "Server", :eReq} in entries
    assert {:announce, "Server", :eObserved} in entries
    refute Enum.any?(entries, &match?({:dequeue, "Watcher", _, _}, &1))

    Supervisor.stop(sup)
  end

  test "a failed spec assertion surfaces as a SafetyViolation, is recorded, and does not cascade" do
    Application.put_env(:p_runtime, :monitoring, true)

    # We start the Watcher directly via start_link, which *links* it to this test process. In the
    # real system a spec is linked to the supervisor, not to the machines that send it events, so a
    # spec crash never reaches a sender through a link. Trap exits here to stand in for that
    # supervisor role, so the link artifact doesn't kill the test; the no-cascade property we
    # actually care about (the fan-out flush not propagating) is asserted via send_event below.
    Process.flag(:trap_exit, true)

    # Start just the Watcher standalone (it registers itself and its observe-set in init), so we
    # control exactly what it observes — no machines sending it a legitimate eReq first.
    {:ok, watcher} = M5Demo.Watcher.start_link(%{id: "Watcher", args: nil})
    wait_until(fn -> {:enter, "Watcher", :Watching} in PRuntime.Trace.entries() end)
    ref = Process.monitor(watcher)

    # Mirror an eResp with no preceding eReq: resps (1) > reqs (0) violates `assert resps <= reqs`.
    # The "sender" is this test process; it must NOT crash even though the monitor does. The send
    # target is unregistered (the send itself is dropped), but the spec fan-out still reaches the
    # Watcher — which is the point.
    log =
      capture_log(fn ->
        assert PRuntime.send_event("test", "no-such-target", :eResp, 1) == :ok
        assert_receive {:DOWN, ^ref, :process, ^watcher, reason}, 1_000
        refute reason == :normal
      end)

    # The violation surfaced cleanly: recorded to the trace, logged as a safety violation, the
    # monitor is dead (and, being :temporary, would not be restarted), and the sender survived
    # (the send_event call above returned :ok rather than crashing this process).
    assert Enum.any?(PRuntime.Trace.entries(), &match?({:assert_failed, "Watcher", _}, &1))
    assert log =~ "P safety violation"
    refute Process.alive?(watcher)
  end

  defp index(entries, entry) do
    idx = Enum.find_index(entries, &(&1 == entry))
    assert idx != nil, "expected trace to contain #{inspect(entry)}"
    idx
  end

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
