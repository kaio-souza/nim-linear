import std/unittest
import nimlinear

suite "smoke":
  test "the package imports":
    check nimlinearVersion.len > 0

suite "optional modules":
  test "the core does not export perturb or Scheduler (M12, M13)":
    check not declared(perturb)
    check not declared(Scheduler)
