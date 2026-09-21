# Repository checks

From the repository root, compile and run the D module checker and its D
fixtures with LDC:

```sh
ldc2 -of=/tmp/scrubbed-check-modules scripts/check_modules.d
/tmp/scrubbed-check-modules source
ldc2 -d-version=moduleCheckRunner -Iscripts -of=/tmp/scrubbed-module-check-fixtures scripts/check_modules.d tests/module_check/run.d
/tmp/scrubbed-module-check-fixtures /tmp/scrubbed-check-modules
```

The checker requires a semantic module doc: a `///` header or an entry naming
the D file in `source/README.md` or its directory's `README.md`. The pinned,
generated `filters.entities_data` table is exempt. It checks module names
against paths and the current dependency direction: `app` uses `cli`; `cli`
may compose the pipeline and filters; `pipeline` does not import CLI or
filters; domain stays independent; filters do not import app/cli and cross-
filter imports are limited to `filters.entities` using `entities_data` and
`mojibake`; content may use domain but not app/cli. New boundary policy needs
a documented decision before changing these rules. Selective-import symbols
after `:` are not module dependencies; imports of a forbidden layer's dotted
child modules are forbidden too.
