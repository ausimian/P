/*
 * M5 fixture for the Elixir backend: spec monitors, fan-out, and announce.
 *
 * Exercises exactly the M5 surface area:
 *   - spec ... observes E1, E2   -- Watcher is a passive monitor, a separate :gen_statem process
 *   - fan-out from sends         -- Watcher observes eReq/eResp as the machines exchange them
 *   - announce E, payload        -- Server announces eObserved; Watcher observes it too
 *   - a safety assertion in a spec -- Watcher asserts it never sees more responses than requests
 *
 * A Main machine asks a Server for a value; the Server announces the value and replies. The
 * Watcher spec sits on the side, counting requests/responses (never sending or creating), and
 * asserts the safety property `resps <= reqs`. The point of the test is that the spec, running as
 * an independent process, observes events mirrored to it synchronously at send/announce time.
 * It avoids constructs from later milestones (foreign calls, loops, the `any` type).
 */

event eReq : machine;   // payload: the requester, so the Server knows whom to reply to
event eResp : int;       // the answer
event eObserved : int;   // announced by the Server purely for the monitor to observe

// Passive monitor. Observes the request/response handshake plus the announced value. It tracks
// counts so it can assert the safety property that a response is never observed without a matching
// request having been observed first.
spec Watcher observes eReq, eResp, eObserved {
  var reqs : int;        // requests observed
  var resps : int;       // responses observed
  var lastAnnounced : int; // most recent announced value (proves announce fan-out reached us)

  start state Watching {
    on eReq do {
      reqs = reqs + 1;
    }
    on eResp do (n: int) {
      resps = resps + 1;
      // Safety: every observed response was preceded by an observed request. Because sends notify
      // monitors synchronously at send time, the request is always observed before the response.
      assert resps <= reqs, "Watcher saw a response without a matching request";
    }
    on eObserved do (n: int) {
      lastAnnounced = n;
    }
  }
}

// Root machine: creates the Server, sends it a request carrying `this` so the reply can come back,
// and halts once the response arrives.
machine Main {
  var server : machine;

  start state Init {
    entry {
      server = new Server();
      send server, eReq, this;
    }
    on eResp do (n: int) {
      raise halt;
    }
  }
}

// Answers a request. Announces the value to the monitors first, then replies to the requester.
machine Server {
  start state Up {
    on eReq do (client: machine) {
      announce eObserved, 99;
      send client, eResp, 99;
    }
  }
}

// Defines Main as the system's main machine. Used by `p check`; harmless for
// `p compile --mode elixir`, which emits code for every machine (and spec) in the program.
test tcReqResp [main=Main]: assert Watcher in { Main, Server };
