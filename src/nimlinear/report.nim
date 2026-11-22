## Stable, human-readable verdict report (M5, D-14, D-20).
##
## Ordered by seq, never by hash order. The same history produces the same
## text on every platform. Requires `$` for `Op` and `Res`.

import ./checker

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
