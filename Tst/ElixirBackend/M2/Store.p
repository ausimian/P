/*
 * M2 fixture for the Elixir backend: payloads and the type system.
 *
 * A single Store machine accumulates state from events carrying a variety of payloads,
 * exercising exactly the M2 surface area:
 *   - primitive payloads and arithmetic (int)            -- eAdd
 *   - a named-tuple payload + named-field access         -- eItem  (type Item)
 *   - an anonymous named-tuple payload                   -- ePut
 *   - seq / set / map construction and mutation
 *   - if/else control flow with field updates
 *   - raise halt
 *
 * It deliberately avoids constructs from later milestones (cross-machine send, new,
 * defer/ignore, foreign calls, loops). The harness drives it from ExUnit and asserts the
 * resulting machine state (via :sys.get_state) plus the transition trace.
 */

type Item = (id: int, qty: int);

event eAdd : int;
event eItem : Item;
event ePut : (key: int, val: int);
event eDone;

machine Store {
  var total : int;
  var nums : seq[int];
  var seen : set[int];
  var prices : map[int, int];
  var lastItem : Item;
  var bigCount : int;

  start state Init {
    entry {
      total = 0;
      goto Running;
    }
  }

  state Running {
    on eAdd do (n: int) {
      total = total + n;
      nums += (sizeof(nums), n);
      seen += (n);
      if (n >= 10) {
        bigCount = bigCount + 1;
      }
    }

    on eItem do (it: Item) {
      lastItem = it;
      total = total + it.qty;
    }

    on ePut do (kv: (key: int, val: int)) {
      prices[kv.key] = kv.val;
    }

    on eDone do {
      raise halt;
    }
  }
}

// Defines Store as the system's main machine. Used by `p check`; harmless for
// `p compile --mode elixir`, which emits code for every machine in the program.
test tcStore [main=Store]: { Store };
