## nimlinear: linearizability checking for histories of concurrent operations.
##
## Re-exports the core. Example models live in `nimlinear/models/*` and are
## imported separately.

import nimlinear/[history, model, checker, report, json]
export history, model, checker, report, json

when compileOption("threads"):
  import nimlinear/recorder
  export recorder

const nimlinearVersion* = "0.0.0"
