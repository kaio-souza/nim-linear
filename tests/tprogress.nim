## P13: `runRounds` records the round in progress, so a run that dies
## inside a round leaves its seed and round behind. The crash test runs this
## same binary as a child process that exits in the middle of round 3.
import std/[hashes, os, osproc, random, strutils, times, unittest]
when not compileOption("threads"):
  suite "progress file":
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
      round: int

  func step(m: typedesc[CModel], s: CState, op: COp): Expected[CState, CRes] {.raises: [].} =
    Expected[CState, CRes](next: s)
  func hash(s: CState): Hash = 0

  var crashAt = 0
  var hangAt = 0
  proc setupObj(o: var Obj, info: RoundInfo) = o.round = info.round
  proc genOp(r: var Rand, thread, index: int): COp = COp()
  proc exec(o: ptr Obj, op: COp): CRes {.gcsafe.} =
    {.cast(gcsafe).}:
      if o.round == crashAt: quit(3)     # dies without running `finally` blocks
      if o.round == hangAt: sleep(60_000) # hangs outside any switch point
    CRes()

  proc cfg(dir: string): RoundsConfig =
    RoundsConfig(threads: 2, rounds: 5, opsPerThread: 1, seed: 7, saveDir: dir, name: "prog")

  let dir = getTempDir() / "nimlinear-tprogress"

  if paramCount() == 1 and paramStr(1) == "hang-child":
    hangAt = 2
    var c = cfg(dir)
    c.roundTimeout = initDuration(milliseconds = 300)
    discard runRounds(c, CState(), CModel, setupObj, genOp, exec)
    quit(0)                                # not reached

  if paramCount() == 1 and paramStr(1) == "crash-child":
    crashAt = 3
    discard runRounds(cfg(dir), CState(), CModel, setupObj, genOp, exec)
    quit(0)                                # not reached

  suite "progress file (P13)":
    setup:
      removeDir(dir)
      createDir(dir)

    test "removed when the run ends":
      let r = runRounds(cfg(dir), CState(), CModel, setupObj, genOp, exec)
      check r.passed
      check r.previousRun == ""
      check not fileExists(progressPath(cfg(dir)))

    test "a crash inside round 3 leaves seed and round behind":
      let (_, code) = execCmdEx(quoteShell(getAppFilename()) & " crash-child")
      check code == 3
      let path = progressPath(cfg(dir))
      check fileExists(path)
      if fileExists(path):
        let text = readFile(path)
        check "round 3 of 5" in text
        check "seed 7" in text
      # The next run reports it, then cleans up.
      let r = runRounds(cfg(dir), CState(), CModel, setupObj, genOp, exec)
      check r.passed
      check "round 3 of 5" in r.previousRun
      check "a previous run did not finish" in r.describe
      check not fileExists(path)

    test "trackProgress = false writes nothing":
      var c = cfg(dir)
      c.trackProgress = false
      check progressPath(c) == ""
      check runRounds(c, CState(), CModel, setupObj, genOp, exec).passed
      check not fileExists(dir / "prog-seed7.inprogress")

    test "watchdog: a round that hangs is reported and the process ends (exit 124)":
      let (output, code) = execCmdEx(quoteShell(getAppFilename()) & " hang-child")
      check code == 124
      check "report written to" in output
      let hung = dir / "prog-seed7-round2.hung.txt"
      check fileExists(hung)
      if fileExists(hung):
        let text = readFile(hung)
        check "round 2 did not end" in text
        check "thread 0:" in text and "thread 1:" in text
      check "round 2 of 5" in readFile(progressPath(cfg(dir)))   # P13 file still there

    test "watchdog: a round that ends in time is not reported":
      var c = cfg(dir)
      c.roundTimeout = initDuration(seconds = 30)
      check runRounds(c, CState(), CModel, setupObj, genOp, exec).passed
      check not fileExists(dir / "prog-seed7-round1.hung.txt")
