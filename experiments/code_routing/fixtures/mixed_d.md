This example explains a bounded counter used by a local tool.

```d
// SPDX-License-Identifier: MIT
size_t boundedCount(const size_t[] values) {
    size_t total;
    foreach (value; values) {
        if (value > 100) return 100;
        total += value;
    }
    return total;
}
```

The prose after the example states the cap explicitly.
