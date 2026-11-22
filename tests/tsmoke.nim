import std/[strutils, unittest]
import nimlinear

suite "smoke":
  test "the package imports":
    check nimlinearVersion.len > 0

suite "optional modules":
  test "the core does not export perturb or Scheduler (M12, M13)":
    check not declared(perturb)
    check not declared(Scheduler)

suite "version":
  test "nimlinearVersion matches nimlinear.nimble":
    const nimble = staticRead("../nimlinear.nimble")
    var v = ""
    for line in nimble.splitLines:
      if line.startsWith("version"):
        v = line.split('"')[1]
    check v.len > 0
    check nimlinearVersion == v
