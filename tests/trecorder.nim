import std/unittest
when not compileOption("threads"):
  suite "recorder":
    test "skipped without threads":
      skip()
else:
  import nimlinear
  import nimlinear/recorder
  import nimlinear/models/register

  type
    Ctx = object
      rec: ptr Recorder[RegOp, RegRes]
      tid: int

  proc worker(c: Ctx) {.thread.} =
    for i in 0 ..< 3:
      let id = c.rec[].begin(c.tid, write(c.tid * 10 + i))
      c.rec[].finish(id, RegRes(ok: true))
      let rid = c.rec[].begin(c.tid, read())
      c.rec[].finish(rid, RegRes(value: c.tid * 10 + i, ok: true))

  suite "recorder":
    test "records from multiple threads":
      var rec = newRecorder[RegOp, RegRes](threads = 2)
      var ths: array[2, Thread[Ctx]]
      for t in 0 ..< 2:
        createThread(ths[t], worker, Ctx(rec: addr rec, tid: t))
      joinThreads(ths)
      let h = rec.snapshot()
      check h.events.len == 24
      for i in 1 ..< h.events.len:
        check h.events[i-1].seqNo < h.events[i].seqNo
      # every op has invoke and return
      var invokes, returns = 0
      for e in h.events:
        if e.kind == ekInvoke: inc invokes else: inc returns
      check invokes == 12
      check returns == 12

    test "pending op is allowed in snapshot":
      var rec = newRecorder[RegOp, RegRes](threads = 1)
      discard rec.begin(0, read())
      let h = rec.snapshot()
      check h.events.len == 1
      check h.events[0].kind == ekInvoke

    test "finish without begin is misuse":
      var rec = newRecorder[RegOp, RegRes](threads = 1)
      rec.finish(OpId(999), RegRes(ok: true))
      expect ArgumentError:
        discard rec.snapshot()

    test "finish twice is misuse":
      var rec = newRecorder[RegOp, RegRes](threads = 1)
      let id = rec.begin(0, read())
      rec.finish(id, RegRes(ok: true))
      rec.finish(id, RegRes(ok: true))
      expect ArgumentError:
        discard rec.snapshot()

    test "thread index out of range is misuse":
      var rec = newRecorder[RegOp, RegRes](threads = 1)
      discard rec.begin(1, read())
      expect ArgumentError:
        discard rec.snapshot()

    test "recorded history is checkable":
      var rec = newRecorder[RegOp, RegRes](threads = 2)
      var ths: array[2, Thread[Ctx]]
      for t in 0 ..< 2:
        createThread(ths[t], worker, Ctx(rec: addr rec, tid: t))
      joinThreads(ths)
      let h = rec.snapshot()
      for e in h.events:
        check int(e.thread) == (int(e.op) - 1) mod 2

    test "record: begin, body, finish, and returns the result":
      var rec = newRecorder[RegOp, RegRes](threads = 1)
      var calls = 0
      let got = rec.record(0, write(3)):
        inc calls
        RegRes(ok: true)
      check got == RegRes(ok: true)
      check calls == 1
      let r = rec.record(0, read()): RegRes(value: 3, ok: true)
      check r.value == 3
      let h = rec.snapshot()
      check h.events.len == 4
      check h.events[0].kind == ekInvoke and h.events[1].kind == ekReturn
      check h.events[0].call == write(3)
      check h.events[3].res == RegRes(value: 3, ok: true)

    test "record: an exception in the body leaves the op pending":
      var rec = newRecorder[RegOp, RegRes](threads = 1)
      proc boom(): RegRes = raise newException(IOError, "boom")
      expect IOError:
        discard rec.record(0, read()): boom()
      let h = rec.snapshot()
      check h.events.len == 1
      check h.events[0].kind == ekInvoke
