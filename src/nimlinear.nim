## nimlinear: linearizability checking for histories of concurrent operations.
##
## Re-exports the core. Example models live in `nimlinear/models/*` and are
## imported separately.

import nimlinear/[history, model, checker, report, json, shrink]
export history, model, checker, report, json, shrink

when compileOption("threads"):
  import nimlinear/[recorder, rounds]
  export recorder, rounds

const nimlinearVersion* = "0.1.0"
