## Stable, human-readable verdict report (M5, D-14, D-20).
##
## Ordered by seq, never by hash order. The same history produces the same
## text on every platform. Requires `$` for `Op` and `Res`.

import std/[algorithm, strutils, tables]
import ./[checker, history]

proc report*[Op, Res](v: Verdict[Op, Res]): string =
  ## Human-readable verdict. Stable text for golden snapshots (`tests/golden/`).
  case v.kind
  of vkLinearizable:
    result = "linearizable\n"
    result.add "order:"
    for id in v.order:
      result.add " " & $id
    result.add "\n"
  of vkNotLinearizable:
    result = "not linearizable\n"
    result.add "prefix:"
    for id in v.witness.prefix:
      result.add " " & $id
    result.add "\n"
    result.add "stuck: op " & $v.witness.stuck & "\n"
    result.add "call: " & $v.witness.stuckCall & "\n"
    result.add "result: " & $v.witness.stuckRes & "\n"
    result.add "alternatives:\n"
    for a in v.witness.alternatives:
      result.add "  - op " & $a.candidate
      result.add ": expected " & $a.expected
      result.add ", observed " & $a.observed
      if a.why.len > 0:
        result.add ", why: " & a.why
      result.add "\n"
  of vkInconclusive:
    result = "inconclusive\n"
    result.add "states explored: " & $v.statesExplored & "\n"
    result.add "budget: " & $v.budget & "\n"
    if v.timedOut:
      result.add "stopped by: timeout\n"

const timelineLimit* = 400
  ## Above this many events, `timeline` prints only the legend.

type OpLine[Op, Res] = object
  id: OpId
  thread: int
  tick, pending: bool
  inv, ret: int          # event positions (columns)
  invSeq, retSeq: int
  call: Op
  res: Res

proc collect[Op, Res](h: History[Op, Res]): seq[OpLine[Op, Res]] =
  var at = initTable[OpId, int]()
  for pos, e in h.events:
    case e.kind
    of ekInvoke, ekTick:
      at[e.op] = result.len
      result.add OpLine[Op, Res](id: e.op, thread: int(e.thread), tick: e.kind == ekTick,
                                 pending: e.kind == ekInvoke, inv: pos, ret: pos,
                                 invSeq: int(e.seqNo), retSeq: int(e.seqNo), call: e.call)
    of ekReturn:
      let i = at.getOrDefault(e.op, -1)
      if i >= 0:
        result[i].pending = false
        result[i].ret = pos
        result[i].retSeq = int(e.seqNo)
        result[i].res = e.res

proc roleOf[Op, Res](v: Verdict[Op, Res], id: OpId): string =
  case v.kind
  of vkLinearizable:
    let k = v.order.find(id)
    if k >= 0: "#" & $(k + 1) else: "not applied"
  of vkNotLinearizable:
    if id == v.witness.stuck: "STUCK"
    else:
      let k = v.witness.prefix.find(id)
      if k >= 0: "prefix #" & $(k + 1) else: ""
  of vkInconclusive: ""

proc timeline*[Op, Res](h: History[Op, Res], v: Verdict[Op, Res]): string =
  ## ASCII timeline (M18): one row per thread, one column per event, in `seq`
  ## order. `[` invoke, `]` return, `=` in between, `>` pending to the end,
  ## `|` tick. A legend lists every operation with its call, result and role
  ## in the verdict (position in `order`, in the `prefix`, or `STUCK`).
  ## Stable text, like `report`.
  let ops = collect(h)
  let width = h.events.len
  var threads: seq[int]
  var hasTicks = false
  for o in ops:
    if o.tick: hasTicks = true
    elif o.thread notin threads: threads.add o.thread
  threads.sort()
  result = "timeline:\n"
  if width > timelineLimit:
    result.add "  (" & $width & " events: drawing omitted above " & $timelineLimit & ")\n"
  else:
    var label = newSeq[string]()
    for t in threads: label.add "thread " & $t
    if hasTicks: label.add "ticks"
    var lw = 0
    for l in label: lw = max(lw, l.len)
    var rows = initTable[int, string]()
    for t in threads: rows[t] = repeat(' ', width)
    var tickRow = repeat(' ', width)
    for o in ops:
      if o.tick:
        tickRow[o.inv] = '|'
        continue
      var r = rows[o.thread]
      let last = if o.pending: width - 1 else: o.ret
      for c in o.inv .. last: r[c] = '='
      r[o.inv] = '['
      if o.pending: r[last] = (if last == o.inv: '[' else: '>')
      else: r[o.ret] = ']'
      rows[o.thread] = r
    for t in threads:
      result.add "  " & alignLeft("thread " & $t, lw) & "  " & rows[t].strip(leading = false) & "\n"
    if hasTicks:
      result.add "  " & alignLeft("ticks", lw) & "  " & tickRow.strip(leading = false) & "\n"
  result.add "operations:\n"
  for o in ops:
    var line = "  op " & $o.id
    if o.tick:
      line.add " (tick, seq " & $o.invSeq & "): " & $o.call
    elif o.pending:
      line.add " (thread " & $o.thread & ", seq " & $o.invSeq & "-): " & $o.call & " -> pending"
    else:
      line.add " (thread " & $o.thread & ", seq " & $o.invSeq & "-" & $o.retSeq & "): " &
               $o.call & " -> " & $o.res
    let role = roleOf(v, o.id)
    if role.len > 0: line.add "  [" & role & "]"
    result.add line & "\n"

proc report*[Op, Res](v: Verdict[Op, Res], h: History[Op, Res]): string =
  ## `report(v)` followed by `timeline(h, v)`.
  report(v) & timeline(h, v)

proc timelineHtml*[Op, Res](h: History[Op, Res], v: Verdict[Op, Res]): string =
  ## Standalone HTML page (M18, no external resources): the timeline as SVG,
  ## with the role of each operation as color, and the text report below.
  ## Hover an operation for its call and result.
  let ops = collect(h)
  var threads: seq[int]
  for o in ops:
    if not o.tick and o.thread notin threads: threads.add o.thread
  threads.sort()
  let colW = 28
  let rowH = 34
  let left = 90
  let w = left + max(1, h.events.len) * colW + 20
  let hgt = (threads.len + 1) * rowH + 20
  proc esc(x: string): string = x.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))
  var svg = "<svg xmlns='http://www.w3.org/2000/svg' width='" & $w & "' height='" & $hgt & "' font-family='monospace' font-size='12'>\n"
  for r, t in threads:
    let y = 20 + r * rowH
    svg.add "<text x='4' y='" & $(y + 16) & "'>thread " & $t & "</text>\n"
  for o in ops:
    let role = roleOf(v, o.id)
    let fill = if role == "STUCK": "#e5484d"
               elif role.startsWith("prefix") or role.startsWith("#"): "#3e7bfa"
               elif o.pending: "#c8c8c8"
               else: "#9aa0a6"
    let title = esc("op " & $o.id & ": " & $o.call & (if o.pending: " -> pending" elif o.tick: "" else: " -> " & $o.res) &
                    (if role.len > 0: " [" & role & "]" else: ""))
    if o.tick:
      let x = left + o.inv * colW + colW div 2
      svg.add "<line x1='" & $x & "' y1='10' x2='" & $x & "' y2='" & $(hgt - 10) &
              "' stroke='#f5a623' stroke-dasharray='4 3'><title>" & title & "</title></line>\n"
      continue
    let r = threads.find(o.thread)
    let y = 20 + r * rowH
    let x0 = left + o.inv * colW + 2
    let x1 = left + (if o.pending: h.events.len else: o.ret + 1) * colW - 2
    svg.add "<g><title>" & title & "</title><rect x='" & $x0 & "' y='" & $y & "' width='" & $(x1 - x0) &
            "' height='22' rx='4' fill='" & fill & "'/><text x='" & $(x0 + 4) & "' y='" & $(y + 15) &
            "' fill='white'>" & esc($o.id & " " & $o.call) & "</text></g>\n"
  svg.add "</svg>\n"
  result = "<!doctype html>\n<html><head><meta charset='utf-8'><title>nimlinear timeline</title>" &
           "<style>body{font-family:sans-serif;margin:16px;background:#fff;color:#111}" &
           "pre{background:#f4f4f4;padding:8px;overflow:auto}.k span{display:inline-block;width:12px;height:12px;margin:0 4px 0 12px}</style>" &
           "</head><body>\n<h1>" & esc(($v.kind)[2 .. ^1]) & "</h1>\n" &
           "<p class='k'>Colors:<span style='background:#3e7bfa'></span>linearized<span style='background:#e5484d'></span>stuck" &
           "<span style='background:#9aa0a6'></span>other<span style='background:#c8c8c8'></span>pending<span style='background:#f5a623'></span>tick</p>\n" &
           "<div style='overflow:auto'>" & svg & "</div>\n<pre>" & esc(report(v, h)) & "</pre>\n</body></html>\n"
