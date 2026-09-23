# Dispatch shipping evidence

This subtree contains the Stage4b evidence-only comparison for issue #155. It
does not set a speed threshold or make an optimization claim. The generated
JSON records local descriptive observations from the unchanged shipping
binary and exact equivalence checks.

Build the canonical shipping binary and the D harness with release
optimization, then write evidence to a new path:

```sh
dub build --compiler=ldc2 --build=release --force
ldc2 -i -O3 -release -Isource experiments/dispatch_shipping/check.d \
  -of=/tmp/scrubbed-dispatch-shipping-check
/tmp/scrubbed-dispatch-shipping-check ./scrubbed \
  /tmp/scrubbed-dispatch-shipping-evidence.json
```

The harness creates only deterministic synthetic UTF-8 fixtures in a fresh
temporary directory, runs a warmup followed by three interleaved v3/v4 pairs,
checks byte-for-byte tree equivalence and deliberate mismatch controls, writes
canonical evidence, reopens and binds every fixture, run, metric, accounting
field, and digest to the observations from that execution, exercises
stale/foreign/mutated evidence negatives, and removes its temporary corpus.
Descriptor evidence requires at least one successful child sample. The copy
probe uses the runtime's cumulative current-thread allocation counter and also
rehashes the retained output after closing the mapped input. The destination
must not already exist.
