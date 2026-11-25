## Peak memory of one check on an exported history, for the comparison with
## Porcupine (docs/MEASUREMENTS.md#memory). Same method as the Go side
## (tests/measure/porcupine, `-mem`): the process's peak resident set
## (VmHWM from /proc/self/status) after parsing only, and after parsing and
## checking. The memory of the check is the difference.
##
##   nim c -d:release --mm:orc -o:DIR/mem tests/measure/memory.nim
##   DIR/mem register FILE load|check
##   DIR/mem queue FILE load|check
##
## Linux only (reads /proc). Histories come from `bench --export:DIR`.
import std/[os, strutils, times]
import nimlinear
import nimlinear/models/[register, boundedqueue]

proc peakRssKb(): int =
  for line in readFile("/proc/self/status").splitLines:
    if line.startsWith("VmHWM:"):
      return line[6 .. ^1].strip().split(' ')[0].parseInt
  raise newException(ValueError, "VmHWM not found")

proc main() =
  if paramCount() != 3:
    quit "usage: mem register|queue FILE load|check", 2
  let model = paramStr(1)
  let text = readFile(paramStr(2))
  let mode = paramStr(3)
  var verdict = ""
  case model
  of "register":
    let h = parseJsonLines[RegOp, RegRes](text)
    if mode == "check":
      let v = checkLinearizable(h, RegState(), RegisterModel, budget = 50_000_000)
      verdict = $v.kind
  of "queue":
    let h = parseJsonLines[QueueOp, QueueRes](text)
    if mode == "check":
      let v = checkLinearizable(h, QueueState(capacity: 100), QueueModel, budget = 50_000_000)
      verdict = $v.kind
  else:
    quit "unknown model: " & model, 2
  echo "rss_kb=", peakRssKb(), " verdict=", verdict

main()
