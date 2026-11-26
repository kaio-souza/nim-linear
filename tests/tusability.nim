## Usability: a run under the OS scheduler only says so in `warnings`.
import std/[hashes, random, strutils, unittest]
when not compileOption("threads"):
  suite "usability":
    test "skipped without threads":
      skip()
else:
  import nimlinear

  type
    COp = object
      x: int
    CRes = object
      value: int
    CState = object
      value: int
    CModel = object
    Obj = object

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    Expected[CState, CRes](next: s, res: CRes())
  func hash(s: CState): Hash = hash(s.value)

  proc setupObj(o: var Obj) = discard
  proc genOp(r: var Rand, thread, index: int): COp = COp()
  proc exec(o: ptr Obj, op: COp): CRes {.gcsafe.} = CRes()

  suite "usability":
    test "OS scheduler only: a warning that suggests -d:nimlinearStrict":
      let r = runRounds(RoundsConfig(threads: 2, rounds: 3), CState(), CModel, setupObj, genOp, exec)
      check r.passed
      when defined(nimlinearPerturb) or defined(nimlinearStrict):
        check r.warnings.len == 0
      else:
        check r.warnings.len == 1
        check "nimlinearStrict" in r.warnings[0]
        check "warning: ran under the OS scheduler only" in r.describe
