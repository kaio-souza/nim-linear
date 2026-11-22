import std/unittest
import nimlinear
import nimlinear/models/boundedqueue

type Ev = Event[QueueOp, QueueRes]
proc op(id, th, inv, ret: int, call: QueueOp, res: QueueRes): seq[Ev] =
  @[invokeEvent[QueueOp, QueueRes](id, th, inv, call), returnEvent[QueueOp, QueueRes](id, th, ret, res)]
proc ids(xs: seq[OpId]): seq[int] =
  for x in xs: result.add int(x)

suite "BoundedQueue model":
  test "linearizable enqueue/dequeue overlap":
    let evs = op(1, 0, 1, 4, enqueue(7), okRes()) & op(2, 1, 2, 3, dequeue(), valueRes(7))
    let v = checkLinearizable(newHistory(evs), QueueState(capacity: 2), QueueModel)
    check v.kind == vkLinearizable
    check ids(v.order) == @[1, 2]

  test "full and empty respected":
    let evs = op(1, 0, 1, 2, enqueue(1), okRes()) & op(2, 0, 3, 4, enqueue(2), fullRes())
    let v = checkLinearizable(newHistory(evs), QueueState(capacity: 1), QueueModel)
    check v.kind == vkLinearizable

  test "close behavior":
    let evs = op(1, 0, 1, 2, close(), okRes()) & op(2, 0, 3, 4, enqueue(1), closedRes()) &
              op(3, 1, 5, 6, dequeue(), closedRes())
    let v = checkLinearizable(newHistory(evs), QueueState(capacity: 1), QueueModel)
    check v.kind == vkLinearizable

  test "duplicate dequeue is not linearizable":
    let evs = op(1, 0, 1, 2, enqueue(7), okRes()) &
              op(2, 1, 3, 6, dequeue(), valueRes(7)) &
              op(3, 2, 4, 5, dequeue(), valueRes(7))
    let v = checkLinearizable(newHistory(evs), QueueState(capacity: 2), QueueModel)
    check v.kind == vkNotLinearizable
