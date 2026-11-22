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
    nextLocal: int   # per-thread op counter; only touched by its own thread

  Recorder*[Op, Res] = object
    counter: Atomic[int]
    bufs: seq[Buf[Op, Res]]
    misuse: Atomic[bool]   # a begin/finish with an invalid thread or id

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
  let k = r.bufs[thread].nextLocal
  inc r.bufs[thread].nextLocal
  let id = OpId(k * r.bufs.len + thread + 1)
  r.bufs[thread].events.add Event[Op, Res](op: id, thread: ThreadId(thread),
                                          seqNo: SeqNo(s), kind: ekInvoke, call: call)
  id

proc finish*[Op, Res](r: var Recorder[Op, Res], id: OpId, res: Res) {.raises: [].} =
  ## Takes the return `seq` after the operation. Call after receiving the
  ## result, from the same thread that called `begin`.
  let s = r.counter.fetchAdd(1) + 1
  if int(id) < 1:
    r.misuse.store(true)
    return
  let thread = (int(id) - 1) mod r.bufs.len
  # Unknown or duplicate ids are recorded as-is; newHistory rejects them.
  r.bufs[thread].events.add Event[Op, Res](op: id, thread: ThreadId(thread),
                                          seqNo: SeqNo(s), kind: ekReturn, res: res)

proc snapshot*[Op, Res](r: var Recorder[Op, Res]): History[Op, Res] {.raises: [ArgumentError].} =
  ## Merges all thread buffers by `seq`. Call only after all threads joined.
  if r.misuse.load:
    raise newException(ArgumentError, "recorder misuse: thread index out of range or invalid OpId")
  var all: seq[Event[Op, Res]]
  for b in r.bufs:
    all.add b.events
  newHistory(all)
