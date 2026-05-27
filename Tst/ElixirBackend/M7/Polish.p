/*
 * M7 fixture for the Elixir backend: the `any` type, and faithful failure surfacing.
 *
 * Exercises exactly the M7 surface area:
 *   - the `any` type            -- a field of type `any` holds heterogeneous values (int, string),
 *                                  a seq[any] and a map[string, any] mix element types, an `any`
 *                                  payload is received, compared to a concrete value, and cast back
 *                                  to a concrete type. `any` rides the existing pass-through codegen
 *                                  (an `any` value is just a BEAM term), so this proves it round-trips.
 *   - unhandled-event surfacing -- the harness delivers `eCheck` to `Ready`, which does not handle
 *                                  it; the generated catch-all now raises PRuntime.UnhandledEvent
 *                                  (and records {:unhandled, ...}) instead of silently dropping it.
 *   - abnormal-crash surfacing  -- an `any` cast is an unchecked pass-through, so summing a string-
 *                                  valued `any` as an int crashes; the generated terminate/3 records
 *                                  {:crash, ...} with machine/state context.
 *
 * A single Vault machine is driven entirely by the harness, which makes the ordering deterministic
 * (sends from one process to one :gen_statem are FIFO) and lets it poke the machine with the
 * unhandled / crashing events without the P program itself having to be ill-formed.
 */

event eStore : any;             // store an arbitrary value in `last`
event eList  : any;             // append an arbitrary value to the seq[any]
event eMap   : (k: string, v: any); // put an arbitrary value under a string key in the map[string, any]
event eSum;                     // fold `last` into an int total (last as int) -- crashes if last isn't an int
event eDone;                    // halt
event eCheck;                   // declared but deliberately NOT handled in Ready (drives the unhandled path)

// Accumulates values of the `any` (top) type across several collections. Nothing here is specific
// to a concrete type until `eSum`, which casts the stored `any` back to int.
machine Vault {
  var last  : any;              // most recently stored value (any type); defaults to nil
  var items : seq[any];         // heterogeneous sequence
  var m     : map[string, any]; // heterogeneous map keyed by string
  var total : int;              // running sum of int-valued `last`s
  var sawFive : bool;           // set when an `any` compared equal to the concrete int 5

  start state Ready {
    on eStore do (v: any) {
      last = v;
      // Compare an `any` against a concrete value: equality works structurally on the BEAM term.
      if (last == 5) {
        sawFive = true;
      }
    }
    on eList do (v: any) {
      items += (sizeof(items), v);
    }
    on eMap do (kv: (k: string, v: any)) {
      m[kv.k] = kv.v;
    }
    on eSum do {
      // Cast the stored `any` back to int. P's cast is unchecked in this backend (a pass-through),
      // matching how the BEAM treats the term: if `last` actually holds an int this folds it in; if
      // it holds a string the int addition crashes, exercising the terminate/3 crash surfacing.
      total = total + (last as int);
    }
    on eDone do {
      raise halt;
    }
  }
}

// Defines Vault as the system's main machine. Used by `p check`; harmless for
// `p compile --mode elixir`, which emits code for every machine in the program.
test tcPolish [main=Vault]: { Vault };
