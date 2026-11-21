# Package

version       = "0.0.0"
author        = "nimlinear contributors"
description   = "Linearizability checker for histories of concurrent operations (stdlib only)"
license       = "MIT"
srcDir        = "src"

# Dependencies

requires "nim >= 2.2.0"

import std/os, std/strutils

# Tasks

task test, "Runs every tests/t*.nim (same loop as CI)":
  var files: seq[string]
  for f in listFiles("tests"):
    let name = f.extractFilename
    if name.startsWith("t") and name.endsWith(".nim"):
      files.add f
  if files.len == 0:
    quit "no test files found in tests/", 1
  for f in files:
    exec "nim c -r --hints:off " & f
