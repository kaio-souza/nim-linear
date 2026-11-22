## Concurrent recorder (M7). Records invoke/return from several threads.
##
## Each thread writes only to its own buffer; `seq` numbers come from a shared
## atomic counter. There is no lock on the hot path: the recording thread is
## encoded in the `OpId` (`id = k * threads + thread + 1`), so `finish` finds
## the buffer without shared lookups. `snapshot` merges the buffers and sorts
## by `seq` (via `newHistory`) after all threads have joined.
## Requires --threads:on. See docs/API.md#recorder and docs/HISTORY.md.

when not compileOption("threads"):
  {.error: "nimlinear/recorder requires --threads:on".}

import std/atomics
import ./history

type
  Buf[Op, Res] = object
    events: seq[Event[Op, Res]]
    nextLocal: int     # per-index op counter
    busy: Atomic[bool] # set while a call writes this buffer

  Recorder*[Op, Res] = object
    counter: Atomic[int]
    bufs: seq[Buf[Op, Res]]
    misuse: Atomic[bool]   # a begin/finish with an invalid thread or id

# A buffer belongs to a logical index, not to an OS thread: an async task may
# `begin` on one OS thread and `finish` on another. What must never happen is
# two calls writing the same buffer at the same time (two OS threads sharing
# an index). `busy` detects exactly that: the second writer finds the flag
# set, records misuse and does not write.
template writeBuf(r, thread, ev: untyped) =
  if r.bufs[thread].busy.exchange(true, moAcquire):
    r.misuse.store(true)       # concurrent use of one index: refuse to write
  else:
    r.bufs[thread].events.add ev
    r.bufs[thread].busy.store(false, moRelease)

proc `=copy`*[Op, Res](dest: var Recorder[Op, Res], src: Recorder[Op, Res]) {.error.}

proc newRecorder*[Op, Res](threads: Positive): Recorder[Op, Res] =
  result.bufs = newSeq[Buf[Op, Res]](threads)
  result.counter.store(0)

proc begin*[Op, Res](r: var Recorder[Op, Res], thread: int, call: Op): OpId {.raises: [].} =
  ## Takes the invoke `seq` before returning. Call before the real operation.
  ## `thread` must be in `0 ..< threads` and used by one thread only.
  let s = r.counter.fetchAdd(1) + 1
  if thread < 0 or thread >= r.bufs.len:
    r.misuse.store(true)
    return OpId(0)
  if r.bufs[thread].busy.exchange(true, moAcquire):
    r.misuse.store(true)
    return OpId(0)
  let k = r.bufs[thread].nextLocal
  inc r.bufs[thread].nextLocal
  let id = OpId(k * r.bufs.len + thread + 1)
  r.bufs[thread].events.add Event[Op, Res](op: id, thread: ThreadId(thread),
                                          seqNo: SeqNo(s), kind: ekInvoke, call: call)
  r.bufs[thread].busy.store(false, moRelease)
  id

proc finish*[Op, Res](r: var Recorder[Op, Res], id: OpId, res: Res) {.raises: [].} =
  ## Takes the return `seq` after the operation. Call after receiving the
  ## result. It may run on another OS thread than `begin` (async tasks that
  ## migrate), as long as no other call uses the same index at the same time.
  let s = r.counter.fetchAdd(1) + 1
  if int(id) < 1:
    r.misuse.store(true)
    return
  let thread = (int(id) - 1) mod r.bufs.len
  # Unknown or duplicate ids are recorded as-is; newHistory rejects them.
  writeBuf(r, thread, Event[Op, Res](op: id, thread: ThreadId(thread),
                                     seqNo: SeqNo(s), kind: ekReturn, res: res))

proc tick*[Op, Res](r: var Recorder[Op, Res], thread: int, call: Op): OpId {.raises: [].} =
  ## Records an instantaneous `tick` (M10), e.g. a fake-clock advance. Call it
  ## right after advancing the clock, from the thread that advanced it.
  let s = r.counter.fetchAdd(1) + 1
  if thread < 0 or thread >= r.bufs.len:
    r.misuse.store(true)
    return OpId(0)
  if r.bufs[thread].busy.exchange(true, moAcquire):
    r.misuse.store(true)
    return OpId(0)
  let k = r.bufs[thread].nextLocal
  inc r.bufs[thread].nextLocal
  let id = OpId(k * r.bufs.len + thread + 1)
  r.bufs[thread].events.add Event[Op, Res](op: id, thread: ThreadId(thread),
                                          seqNo: SeqNo(s), kind: ekTick, call: call)
  r.bufs[thread].busy.store(false, moRelease)
  id

template record*[Op, Res](r: var Recorder[Op, Res], thread: int, call: Op,
                          body: untyped): Res =
  ## `begin`, evaluates `body` (the real operation, which must give a `Res`),
  ## `finish` with that result, and returns it:
  ##
  ##   let got = rec.record(myId, dequeue()):
  ##     toRes(queue.tryDequeue())
  ##
  ## If `body` raises, `finish` is not called and the operation stays pending.
  let recPtr = addr(r)
  let recId = recPtr[].begin(thread, call)
  let recRes: Res = body
  recPtr[].finish(recId, recRes)
  recRes

proc snapshot*[Op, Res](r: var Recorder[Op, Res]): History[Op, Res] {.raises: [ArgumentError].} =
  ## Merges all thread buffers by `seq`. Call only after all threads joined.
  if r.misuse.load:
    raise newException(ArgumentError, "recorder misuse: thread index out of range, invalid OpId, " &
      "or one index used by two threads at the same time")
  var all: seq[Event[Op, Res]]
  for b in r.bufs:
    all.add b.events
  newHistory(all)
