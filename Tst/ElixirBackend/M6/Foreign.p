/*
 * M6 fixture for the Elixir backend: foreign types and foreign functions.
 *
 * Exercises exactly the M6 surface area:
 *   - a foreign type            -- `Accumulator` is opaque to the generated code (a host term)
 *   - foreign functions (value) -- newAccumulator/accumulate/digest are called in expression
 *                                  position; the generated code maps each to PForeign.<name>(args)
 *   - a foreign function (void) -- noteValue is called for effect, as a statement
 *
 * A single Main machine builds an opaque Accumulator via the host's PForeign module, folds a few
 * ints into it, then digests it to an int. The generated code never looks inside the Accumulator —
 * it only passes it between PForeign calls — which is the whole point of a foreign type. The host
 * (the ExUnit harness) supplies PForeign; the generated FOREIGN.md is the stub it was written from.
 * It avoids constructs from later milestones (loops, calls to P functions with bodies, the `any` type).
 */

// A foreign (opaque) type, implemented by the host in Elixir. P declares it but never constructs
// or inspects a value of it; only PForeign functions do.
type Accumulator;

// Foreign functions: declared with no body, implemented by the host's PForeign module.
fun newAccumulator() : Accumulator;                       // construct an empty accumulator
fun accumulate(acc: Accumulator, value: int) : Accumulator; // fold one value in (returns the new acc)
fun digest(acc: Accumulator) : int;                        // collapse the accumulator to an int
fun noteValue(value: int);                                 // side-effect only (no return)

event eAdd : int;    // fold this value into the accumulator
event eDigest;       // collapse the accumulator into `result`

machine Main {
  var acc : Accumulator;   // foreign-typed field; opaque to generated code, defaults to nil
  var result : int;        // the digested result, observable from the test

  start state Init {
    entry {
      // Build the opaque handle through the host. The generated code stores whatever PForeign
      // returns without interpreting it.
      acc = newAccumulator();
      goto Counting;
    }
  }

  state Counting {
    on eAdd do (v: int) {
      noteValue(v);            // foreign call for effect (statement position)
      acc = accumulate(acc, v); // foreign call in value position; result rebinds the field
    }
    on eDigest do {
      result = digest(acc);     // foreign call producing the observable result
      goto Done;
    }
  }

  // Terminal resting state: `result` holds the digest, which the harness reads via :sys.get_state.
  state Done { }
}

// Defines Main as the system's main machine. Used by `p check`; harmless for
// `p compile --mode elixir`, which emits code for every machine in the program.
test tcForeign [main=Main]: { Main };
