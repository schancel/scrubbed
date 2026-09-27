/// Shared `--flag value` / `--flag=value` tokenizer for effects-layer CLI
/// entry points (issue #351). `crawl_cli.d`, `error_cli.d`, and
/// `metadata_route_cli.d` each hand-rolled an identical copy of this loop
/// body; `error_cli.d`'s copy was missing the NUL-byte/empty-value rejection
/// the other two had, which is exactly the kind of drift a shared helper is
/// meant to make impossible. Boolean, no-value flags (`--in-memory`,
/// `--retry`, ...) are still each caller's own concern -- they're checked
/// against `args[i]` before ever calling into this helper.
module effects.cli_option_parsing;

import std.string : indexOf, startsWith;

/// One decoded flag/value pair pulled off the front of an argv-style token
/// stream, or a failure signal. `flag` and `value` are only meaningful when
/// `ok` is true.
struct ParsedOption {
    string flag;
    string value;
    bool ok;
}

/// Decodes the option at `args[i]`, handling both the `--flag=value`
/// one-token form and the `--flag value` two-token form, and advances `i`
/// past whichever tokens were consumed -- one for the `=` form, two for the
/// space-separated form -- regardless of whether decoding succeeded, so a
/// caller can always resume iteration at the returned `i` (though callers
/// that reject the whole parse on first failure, as all three current ones
/// do, never actually need to).
///
/// Fails (`ok == false`) when: the two-token form has no following token;
/// that following token itself looks like another flag (starts with
/// `"--"`); the resulting value is empty; or the value contains a NUL byte.
/// This is the exact check `crawl_cli.d` and `metadata_route_cli.d` already
/// had and `error_cli.d` was missing.
ParsedOption nextOption(const string[] args, ref size_t i)
in (i < args.length) {
    string flag = args[i];
    auto equal = flag.indexOf('=');
    string value;
    if (equal >= 0) {
        value = flag[equal + 1 .. $];
        flag = flag[0 .. equal];
        ++i;
    } else {
        ++i;
        if (i >= args.length || args[i].startsWith("--"))
            return ParsedOption(flag, null, false);
        value = args[i];
        ++i;
    }
    if (!value.length || value.indexOf('\0') >= 0)
        return ParsedOption(flag, value, false);
    return ParsedOption(flag, value, true);
}

version (unittest) {
    private ParsedOption parseAt(string[] args, size_t start) {
        size_t i = start;
        return nextOption(args, i);
    }
}

unittest {
    // `--flag=value` one-token form.
    auto r = parseAt(["--foo=bar"], 0);
    assert(r.ok && r.flag == "--foo" && r.value == "bar");
}

unittest {
    // `--flag value` two-token form.
    size_t i;
    auto r = nextOption(["--foo", "bar", "--next"], i);
    assert(r.ok && r.flag == "--foo" && r.value == "bar");
    assert(i == 2, "should advance past both consumed tokens");
}

unittest {
    // Two-token form with nothing following is malformed.
    size_t i;
    auto r = nextOption(["--foo"], i);
    assert(!r.ok);
}

unittest {
    // Two-token form where the next token looks like a flag is malformed
    // (it's almost certainly a missing value, not an intentional one).
    size_t i;
    auto r = nextOption(["--foo", "--bar"], i);
    assert(!r.ok);
}

unittest {
    // Empty value, either spelling, is rejected.
    assert(!parseAt(["--foo="], 0).ok);
    size_t i;
    assert(!nextOption(["--foo", ""], i).ok);
}

unittest {
    // A NUL byte embedded in the value is rejected, either spelling. This is
    // the exact regression #351 closes: `error_cli.d`'s hand-rolled copy of
    // this loop had no equivalent check.
    assert(!parseAt(["--foo=ba\0r"], 0).ok);
    size_t i;
    assert(!nextOption(["--foo", "ba\0r"], i).ok);
}

unittest {
    // A value that merely starts with "--" is fine when spelled with `=`
    // (the flag/value split is unambiguous there) -- only the two-token
    // lookahead treats a leading "--" as "this is actually the next flag".
    auto r = parseAt(["--foo=--not-a-flag"], 0);
    assert(r.ok && r.value == "--not-a-flag");
}
