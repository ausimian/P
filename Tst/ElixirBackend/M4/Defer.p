/*
 * M4 fixture for the Elixir backend: defer, ignore, and (non-halt) raise.
 *
 * A single Worker machine, driven from ExUnit, exercises exactly the M4 surface area:
 *   - defer E              -- eWork is deferred in Buffering, re-delivered after the state change
 *   - ignore E             -- eNoise is dropped in Buffering with no effect
 *   - on E goto S          -- eFlush moves Buffering -> Draining
 *   - raise E (non-halt)   -- eGo raises eDone, which is then handled in the same state
 *   - raise halt           -- eDone halts the machine
 *
 * The point of the test is the deferral round-trip: events deferred in Buffering must NOT be
 * handled there, but must be re-delivered (in order, front of queue) once the machine reaches
 * Draining, which handles them. It avoids constructs from later milestones (announce, specs,
 * foreign calls, loops).
 */

event eWork : int;   // deferred in Buffering, handled in Draining (carries a value to accumulate)
event eNoise;        // ignored in Buffering
event eFlush;        // Buffering -> Draining
event eGo;           // in Draining, raises eDone
event eDone;         // ends the machine

machine Worker {
  var handled : int;   // sum of eWork payloads handled (only reachable in Draining)
  var count   : int;   // number of eWork events handled

  start state Buffering {
    defer eWork;       // hold eWork until we leave this state
    ignore eNoise;     // drop eNoise outright
    on eFlush goto Draining;
  }

  state Draining {
    on eWork do (n: int) {
      handled = handled + n;
      count = count + 1;
    }

    on eGo do {
      raise eDone;     // non-halt raise: eDone is queued front and handled below
    }

    on eDone do {
      raise halt;
    }
  }
}

// Defines Worker as the system's main machine. Used by `p check`; harmless for
// `p compile --mode elixir`, which emits code for every machine in the program.
test tcWorker [main=Worker]: { Worker };
