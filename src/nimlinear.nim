## nimlinear: linearizability checking for histories of concurrent operations.
##
## Re-exports the core. Example models live in `nimlinear/models/*` and are
## imported separately.

import nimlinear/[history, model, checker, json]
export history, model, checker, json

const nimlinearVersion* = "0.0.0"
