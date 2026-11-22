## -d:nimlinearVerifyPartition: checkPartitioned cross-checks with
## checkLinearizable and fails loudly on an invalid partition (D-12).
import std/[hashes, unittest]
import nimlinear
import ./oracle/kvttl

# An INVALID partition: a register (one global value) split by the written
# value, so a read and the write it depends on end up in different parts.
type
  ROp = object
    write: bool
    value: int
  RRes = object
    value: int
  RState = object
    value: int
  BadModel = object
func hash(s: RState): Hash = hash(s.value)
func step(m: typedesc[BadModel], s: RState, op: ROp): Expected[RState, RRes] {.raises: [].} =
  if op.write: Expected[RState, RRes](next: RState(value: op.value), res: RRes())
  else: Expected[RState, RRes](next: s, res: RRes(value: s.value))
func partition(m: typedesc[BadModel], op: ROp): int {.raises: [].} = op.value

suite "nimlinearVerifyPartition":
  test "a valid partition passes the cross-check":
    let evs = @[invokeEvent[KvOp, KvRes](1, 0, 1, put(0, 5)), returnEvent[KvOp, KvRes](1, 0, 2, KvRes()),
                invokeEvent[KvOp, KvRes](2, 0, 3, get(0)), returnEvent[KvOp, KvRes](2, 0, 4, KvRes(value: 5))]
    check checkPartitioned(newHistory(evs), initKv(), KvModel).kind == vkLinearizable

  test "an invalid partition is caught":
    # write(5), then read() -> 0 (key 0): the parts say linearizable, the
    # whole history does not.
    let evs = @[invokeEvent[ROp, RRes](1, 0, 1, ROp(write: true, value: 5)), returnEvent[ROp, RRes](1, 0, 2, RRes()),
                invokeEvent[ROp, RRes](2, 0, 3, ROp()), returnEvent[ROp, RRes](2, 0, 4, RRes(value: 0))]
    expect AssertionDefect:
      discard checkPartitioned(newHistory(evs), RState(), BadModel)
