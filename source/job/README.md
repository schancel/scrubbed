# Job specification ownership

This subtree owns the pure, versioned description of a linear scrubbed job.
It performs no file, network, registry, stage, filter, or effect work.

[`spec.d`](spec.d) defines typed text/integer/boolean options, ordered filters,
stable stage-instance IDs, registered implementation names, and the shared
`JobSpec`. An instance ID is durable job identity; it is deliberately not the
stage registry key, so one registered implementation can occur more than once.

[`json.d`](json.d) strictly parses v3 JSON, rejects duplicate and unknown keys,
emits fixed-order canonical JSON with sorted option keys, and derives the
`job:v3:` SHA-256 identity from those bytes.

[`cli_tokens.d`](cli_tokens.d) lowers ordered composition tokens. A `--stage`
opens an owner; subsequent stage options and filters attach in declaration
order. CLI option values carry an explicit `text:`, `integer:`, or `boolean:`
tag so their identity never depends on inference.

[`legacy.d`](legacy.d) is the compatibility edge for the no-selector default,
`--filters`, and v1 filter JSON forms. All produce one implicit
`legacy-text=text-transform` stage in the same `JobSpec`; there is no second
legacy execution model here.

Runtime factory resolution and document/effect execution do not belong in
this subtree. A later composition root may depend on `job`, `stages`, and
`pipeline`; `job` must not import any of them or concrete I/O.

The additive `dispatch_spec.d`, `dispatch_json.d`, and
`dispatch_cli_tokens.d` modules own the pure v4 dispatch-plan format. Its
roots are exactly `version`, `dispatch`, and `common`; the latter is one
nested canonical v3 job. Detector/container limits and every route, typed
route option, and normalized-outcome action are materialized. Canonical JSON
sorts routes and option keys, emits actions in enum order, and derives a
`job:v4:` identity. These pure token/JSON boundaries are intentionally not
accepted by the shipping argparse surface in this slice.
