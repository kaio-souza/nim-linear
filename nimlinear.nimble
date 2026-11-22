# Package

version       = "0.0.0"
author        = "nimlinear contributors"
description   = "Linearizability checker for histories of concurrent operations (stdlib only)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"

# Tasks: the same runner as CI (tools/run.nims). Extra compiler flags go in
# the NIMFLAGS environment variable.

task test, "Runs every tests/t*.nim (same runner as CI)":
  exec "nim e tools/run.nims"

task examples, "Compiles and runs every examples/*.nim":
  putEnv("NIMLINEAR_RUN", "examples")
  exec "nim e tools/run.nims"

task bench, "Runs the benchmark suite with --check":
  putEnv("NIMLINEAR_RUN", "bench")
  exec "nim e tools/run.nims"
