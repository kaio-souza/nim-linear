## Sequential model contract. See docs/MODELS.md#contract.

type
  Expected*[S, Res] = object
    next*: S          ## state after the operation
    res*: Res         ## result the specification expects
    why*: string      ## reason, when the result is a refusal (diagnostics only)
