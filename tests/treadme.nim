## The quickstart in README.md is examples/quickstart.nim, byte for byte
## (the example is compiled and run in CI).
import std/[os, strutils, unittest]

const root = currentSourcePath.parentDir.parentDir

suite "README":
  test "quickstart block equals examples/quickstart.nim":
    let readme = readFile(root / "README.md")
    let a = readme.find("<!-- quickstart:begin -->\n```nim\n")
    let b = readme.find("```\n<!-- quickstart:end -->")
    check a >= 0 and b > a
    let shown = readme[a + "<!-- quickstart:begin -->\n```nim\n".len ..< b]
    check shown == readFile(root / "examples" / "quickstart.nim")
