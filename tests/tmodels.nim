## P2/P3: Map, Stack and Semaphore models (hand-written cases, JSON round
## trip, partition) and the default operation generators of every model.
import std/[random, sets, unittest]
import nimlinear
import nimlinear/models/[map, stack, semaphore, register, boundedqueue, eventflag]

proc op[Op, Res](id, th, inv, ret: int, call: Op, res: Res): seq[Event[Op, Res]] =
  @[invokeEvent[Op, Res](id, th, inv, call), returnEvent[Op, Res](id, th, ret, res)]

template roundTrip(h: untyped, Op, Res: typedesc) =
  let text = h.toJsonLines
  check parseJsonLines[Op, Res](text).toJsonLines == text

suite "Map model":
  test "sequential get/put/delete":
    let h = newHistory(op(1, 0, 1, 2, get(1), missing()) &
                       op(2, 0, 3, 4, put(1, 10), missing()) &
                       op(3, 0, 5, 6, put(1, 11), found(10)) &
                       op(4, 0, 7, 8, get(1), found(11)) &
                       op(5, 0, 9, 10, delete(1), found(11)) &
                       op(6, 0, 11, 12, delete(1), missing()))
    check checkLinearizable(h, initMapState(), MapModel).kind == vkLinearizable
    check checkPartitioned(h, initMapState(), MapModel).kind == vkLinearizable
    roundTrip(h, MapOp, MapRes)

  test "initial entries; overlapping puts on two keys":
    let h = newHistory(op(1, 0, 1, 4, put(1, 5), found(1)) &
                       op(2, 1, 2, 3, put(2, 6), missing()) &
                       op(3, 1, 5, 6, get(1), found(5)))
    check checkPartitioned(h, initMapState([(1, 1)]), MapModel).kind == vkLinearizable

  test "lost put is not linearizable, per key too":
    # Both puts claim the key was empty; one of them must have seen the other.
    let h = newHistory(op(1, 0, 1, 2, put(7, 1), missing()) &
                       op(2, 1, 3, 4, put(7, 2), missing()) &
                       op(3, 2, 5, 6, get(8), missing()))
    check checkLinearizable(h, initMapState(), MapModel).kind == vkNotLinearizable
    let v = checkPartitioned(h, initMapState(), MapModel)
    check v.kind == vkNotLinearizable
    check v.witness.stuck == OpId(2)

  test "initMapState sorts and keeps the last value":
    check initMapState([(3, 1), (1, 2), (3, 4)]).entries == @[(1, 2), (3, 4)]

suite "Stack model":
  test "LIFO and empty":
    let h = newHistory(op(1, 0, 1, 2, push(1), pushed()) &
                       op(2, 0, 3, 4, push(2), pushed()) &
                       op(3, 1, 5, 6, pop(), popped(2)) &
                       op(4, 1, 7, 8, pop(), popped(1)) &
                       op(5, 0, 9, 10, pop(), empty()))
    check checkLinearizable(h, StackState(), StackModel).kind == vkLinearizable
    roundTrip(h, StackOp, StackRes)

  test "FIFO order is not linearizable":
    let h = newHistory(op(1, 0, 1, 2, push(1), pushed()) &
                       op(2, 0, 3, 4, push(2), pushed()) &
                       op(3, 1, 5, 6, pop(), popped(1)))
    check checkLinearizable(h, StackState(), StackModel).kind == vkNotLinearizable

  test "overlap allows either order; capacity":
    let h = newHistory(op(1, 0, 1, 4, push(1), pushed()) &
                       op(2, 1, 2, 3, pop(), popped(1)))
    check checkLinearizable(h, StackState(), StackModel).kind == vkLinearizable
    let f = newHistory(op(1, 0, 1, 2, push(1), pushed()) & op(2, 0, 3, 4, push(2), full()))
    check checkLinearizable(f, StackState(capacity: 1), StackModel).kind == vkLinearizable
    check checkLinearizable(f, StackState(), StackModel).kind == vkNotLinearizable

  test "duplicate pop is not linearizable":
    let h = newHistory(op(1, 0, 1, 2, push(1), pushed()) &
                       op(2, 1, 3, 6, pop(), popped(1)) &
                       op(3, 2, 4, 5, pop(), popped(1)))
    check checkLinearizable(h, StackState(), StackModel).kind == vkNotLinearizable

suite "Semaphore model":
  test "permits, refusal, over-release":
    let h = newHistory(op(1, 0, 1, 2, tryAcquire(), SemRes(ok: true)) &
                       op(2, 1, 3, 4, tryAcquire(), SemRes(ok: false)) &
                       op(3, 0, 5, 6, release(), SemRes(ok: true)) &
                       op(4, 1, 7, 8, release(), SemRes(ok: false)))
    check checkLinearizable(h, initSemState(1), SemaphoreModel).kind == vkLinearizable
    roundTrip(h, SemOp, SemRes)

  test "two holders of one permit is not linearizable":
    let h = newHistory(op(1, 0, 1, 3, tryAcquire(), SemRes(ok: true)) &
                       op(2, 1, 2, 4, tryAcquire(), SemRes(ok: true)))
    check checkLinearizable(h, initSemState(1), SemaphoreModel).kind == vkNotLinearizable
    check checkLinearizable(h, initSemState(2), SemaphoreModel).kind == vkLinearizable

suite "default generators (P3)":
  test "deterministic, cover every operation kind, unique written values":
    template cover(gen, Kind: untyped, n: int) =
      var a = initRand(7)
      var b = initRand(7)
      var kinds: set[Kind]
      for i in 0 ..< n:
        let x = gen(a, 1, i)
        check x == gen(b, 1, i)
        kinds.incl x.kind
      check kinds.card == high(Kind).ord + 1
    cover(genMapOp, MapOpKind, 200)
    cover(genStackOp, StackOpKind, 200)
    cover(genSemaphoreOp, SemOpKind, 200)
    cover(genRegisterOp, RegOpKind, 200)
    cover(genEventOp, EventOpKind, 200)
    var r = initRand(1)
    var qk: set[QueueOpKind]
    for i in 0 ..< 400: qk.incl randomQueueOp(r, 0, i, closePercent = 10).kind
    check qk == {qEnqueue, qDequeue, qClose}
    var seen = initHashSet[int]()
    r = initRand(3)
    for t in 0 ..< 3:
      for i in 0 ..< 50:
        let o = genStackOp(r, t, i)
        if o.kind == sPush:
          check o.value notin seen
          seen.incl o.value

  test "map keys stay in range":
    var r = initRand(5)
    for i in 0 ..< 200:
      check randomMapOp(r, 0, i, keys = 2).key in 0 .. 1
