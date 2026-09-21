# Repository checks

From the repository root, compile and run the D module checker and its D
fixtures with LDC:

```sh
ldc2 -of=/tmp/scrubbed-check-modules scripts/check_modules.d
/tmp/scrubbed-check-modules source
ldc2 -d-version=moduleCheckRunner -Iscripts -of=/tmp/scrubbed-module-check-fixtures scripts/check_modules.d tests/module_check/run.d
/tmp/scrubbed-module-check-fixtures /tmp/scrubbed-check-modules
ldc2 -unittest -main -d-version=moduleCheckRunner -of=/tmp/scrubbed-module-edge-tests scripts/check_modules.d
/tmp/scrubbed-module-edge-tests
```

The checker requires a semantic module doc: a `///` header or an entry naming
the D file in `source/README.md` or its directory's `README.md`. The pinned,
generated `filters.entities_data` table is exempt. It checks module names
against paths and the current dependency direction: `app` uses `cli`; `cli`
may compose the pipeline and filters; `pipeline` does not import CLI or
filters; domain stays independent; filters do not import app/cli and cross-
filter imports are limited to `filters.entities` using `entities_data` and
`mojibake`. Content may import domain/content, stages may import
domain/content/stages, and effects may import domain/content/stages/effects.
Domain, content, and stages may not directly import effects or known concrete
I/O modules (`std.file`, `std.mmfile`, `std.socket`, `std.net`, `std.stdio`,
`std.process`); effects may import concrete I/O. This is a direct-import check,
not proof that a transitive dependency performs no I/O. The final two commands
run the checker's own D unittests, including generated good/bad edge fixtures;
the preceding fixture runner alone does not run them. Selective-import symbols
after `:` are not module dependencies; imports of a forbidden layer's dotted
child modules are forbidden too.
