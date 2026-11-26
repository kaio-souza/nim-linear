## Model from a sequential implementation (P10). Optional; not imported by
## the core.
##
## Lincheck uses the data structure itself, run sequentially, as the
## specification. `sequentialModel` does the same for nimlinear: give it a
## state type and a procedure that applies one operation to a state and
## returns the result, and it defines the model's `step`:
##
##   type SeqQueue = object
##     items: seq[int]
##   proc apply(q: var SeqQueue, op: QueueOp): QueueRes = ...
##   func hash(q: SeqQueue): Hash = hash(q.items)
##
##   sequentialModel(QueueSpec, SeqQueue, QueueOp, QueueRes, apply)
##   checkLinearizable(h, SeqQueue(), QueueSpec)
##
## Requirements, otherwise the verdict is wrong:
## - The state is copied by value: `var next = s` must not share mutable
##   memory with `s`. Plain objects, `seq`, `string`, arrays and tuples are
##   copied deeply by Nim; a `ref` or `ptr` inside is shared, so `apply`
##   would change states the checker already memoized. Under
##   `-d:nimlinearDebug`, `step` checks that `s` kept its hash and fails loudly
##   if `apply` changed it.
## - `hash` and `==` compare by value (D-04).
## - `apply` is deterministic and has no side effects (R8: it runs inside a
##   `func`).
## - The sequential implementation must be correct: a bug present both in it
##   and in the concurrent code is invisible.
##
## Cost: one copy of the state per checker step; a hand-written model with a
## small state is cheaper. The hand-written model stays the default (MODELS.md).

import ./model

template sequentialModel*(name: untyped, S, Op, Res: typedesc, apply: untyped) =
  ## Declares the model type `name` and its `step`, built from
  ## `apply(state: var S, op: Op): Res`.
  type name* = object
  func step*(m: typedesc[name], s: S, op: Op): Expected[S, Res] =
    mixin hash
    when defined(nimlinearDebug):
      let before = hash(s)
    var next = s
    let r = apply(next, op)
    when defined(nimlinearDebug):
      doAssert hash(s) == before, "sequentialModel: `apply` changed the state it was " &
        "given through shared memory (a ref or ptr inside " & $S & "); the state must be " &
        "copied by value (nimlinear/seqmodel)"
    Expected[S, Res](next: next, res: r)
