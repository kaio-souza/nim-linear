# Single test runner, used by `nimble test` and by CI, so both do the same.
#
#   nim e tools/run.nims                       # tests/t*.nim
#   NIMLINEAR_RUN=examples nim e tools/run.nims
#   NIMLINEAR_RUN=bench nim e tools/run.nims   # benchmark with --check
#   NIMFLAGS="--mm:arc --threads:off -d:release" nim e tools/run.nims
#
# Fails if a target directory has no files (so CI cannot pass by running
# nothing). Per-file options go in `<file>.nims` next to the file.
import std/[os, strutils]

let flags = getEnv("NIMFLAGS")
let what = getEnv("NIMLINEAR_RUN", "tests")

proc run(cmd: string) =
  echo "$ ", cmd
  exec cmd

case what
of "tests", "examples":
  let (dir, prefix) = if what == "tests": ("tests", "t") else: ("examples", "")
  var files: seq[string]
  for f in listFiles(dir):
    let name = f.extractFilename
    if name.startsWith(prefix) and name.endsWith(".nim"): files.add f
  if files.len == 0:
    quit "no files to run in " & dir & "/", 1
  for f in files:
    run "nim c -r --hints:off " & flags & " " & f.quoteShell
of "bench":
  run "nim c -r --hints:off -d:release --mm:orc " & flags & " tests/measure/bench.nim --check"
else:
  quit "NIMLINEAR_RUN must be tests, examples or bench, got " & what, 1
