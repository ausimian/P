/*
 * Minimal M1 fixture for the Elixir backend (the "walking skeleton").
 *
 * One machine, two states, one payload-less event, halt — exactly the M1 scope.
 * Walker starts in A, whose entry immediately transitions to B; in B it waits for
 * event E and then halts. This exercises: machine creation, state entry, a goto
 * (exit-less, since A has no exit), event dequeue, and `raise halt`.
 */

event E;

machine Walker {
  start state A {
    entry {
      goto B;
    }
  }

  state B {
    on E do {
      raise halt;
    }
  }
}

// Defines Walker as the system's main machine. Used by `p check`; harmless for
// `p compile --mode elixir`, which emits code for every machine in the program.
test tcWalker [main=Walker]: { Walker };
