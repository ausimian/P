/*
 * M3 fixture for the Elixir backend: multiple machines, dynamic creation, and sends.
 *
 * Exercises exactly the M3 surface area:
 *   - new MachineName(args)        -- Main creates a Ponger (no args) and a Pinger (a machine arg)
 *   - cross-machine send + payload -- Pinger sends ePing carrying `this` to Ponger
 *   - cross-machine send, no args  -- Ponger replies ePong to the sender it was told about
 *   - `this` as an opaque ref      -- Pinger identifies itself to Ponger so Ponger can reply
 *   - the registry                 -- targets are addressed by opaque id, resolved to a pid
 *   - a bounded goto loop + halt   -- Pinger pings 3 times, then halts
 *
 * Main is the only "root" machine (nothing creates it), so the generated supervisor starts
 * just Main; Pinger and Ponger are spawned under the DynamicSupervisor by `new`. It avoids
 * constructs from later milestones (defer/ignore, announce, specs, foreign calls).
 */

event ePing : machine;   // payload: the pinger, so the ponger knows whom to reply to
event ePong;             // payload-less reply

machine Main {
  start state Init {
    entry {
      var ponger : machine;
      ponger = new Ponger();        // `new` as an expression: keep the ref to wire the pinger
      new Pinger(ponger);           // `new` as a statement: the ref is not needed afterwards
    }
  }
}

machine Pinger {
  var ponger : machine;
  var count : int;

  start state Init {
    entry (p: machine) {
      ponger = p;
      count = 0;
      goto Pinging;
    }
  }

  state Pinging {
    entry {
      send ponger, ePing, this;
    }

    on ePong do {
      count = count + 1;
      if (count >= 3) {
        raise halt;
      } else {
        goto Pinging;
      }
    }
  }
}

machine Ponger {
  start state Wait {
    on ePing do (from: machine) {
      send from, ePong;
    }
  }
}

// Defines Main as the system's main machine. Used by `p check`; harmless for
// `p compile --mode elixir`, which emits code for every machine in the program.
test tcPingPong [main=Main]: { Main, Pinger, Ponger };
