import std/unittest
import nimlinear

suite "smoke":
  test "the package imports":
    check nimlinearVersion.len > 0
