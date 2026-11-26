## `RoundsConfig.reduce` is refused without -d:nimlinearInterceptLoads (a load
## that is not a switch point is an access the reduction cannot see).
## Compiled with -d:nimlinearPerturb only (treduce_noloads.nims).
import std/[hashes, random, strutils, unittest]
when not compileOption("threads"):
  suite "reduce without loads":
    test "skipped without threads":
      skip()
else:
  import nimlinear

  type
    COp = object
    CRes = object
    CState = object
    CModel = object
    Obj = object
  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    Expected[CState, CRes](next: s)
  func hash(s: CState): Hash = 0
  proc setupObj(o: var Obj) = discard
  proc genOp(r: var Rand, thread, index: int): COp = COp()
  proc exec(o: ptr Obj, op: COp): CRes {.gcsafe.} = CRes()

  suite "reduce without loads":
    test "refused with a message that names the missing define":
      check not defined(nimlinearInterceptLoads)
      try:
        discard runRounds(RoundsConfig(threads: 2, rounds: 1, explore: true, reduce: true,
                                       trackProgress: false),
                          CState(), CModel, setupObj, genOp, exec)
        check false                      # must not get here
      except ValueError as e:
        check "nimlinearInterceptLoads" in e.msg

    test "explore without reduce still runs":
      check runRounds(RoundsConfig(threads: 2, rounds: 1, explore: true, trackProgress: false),
                      CState(), CModel, setupObj, genOp, exec).passed
