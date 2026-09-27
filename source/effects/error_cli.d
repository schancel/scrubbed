/// Fixed-diagnostic boundary for explicit, opt-in v2 journal commands.
module effects.error_cli;

import effects.cli_option_parsing : nextOption;
import effects.failure_journal : createV2, copyV1ToV2;
import effects.durable_job : createJournalV3;
import effects.error_export : exportV2, verifyV2Export;
import std.stdio : stderr;

private struct Options {
    string journal, fromV1, errorsJsonl, outstandingJsonl;
    bool hasJournal, hasFromV1, hasErrorsJsonl, hasOutstandingJsonl;
}

private bool parseOptions(const string[] args, ref Options options) {
    for (size_t i; i < args.length; ) {
        auto parsed = nextOption(args, i);
        if (!parsed.ok) return false;
        string flag = parsed.flag;
        string value = parsed.value;
        switch (flag) {
        case "--journal":
            if (options.hasJournal) return false;
            options.journal = value; options.hasJournal = true; break;
        case "--from-v1":
            if (options.hasFromV1) return false;
            options.fromV1 = value; options.hasFromV1 = true; break;
        case "--errors-jsonl":
            if (options.hasErrorsJsonl) return false;
            options.errorsJsonl = value; options.hasErrorsJsonl = true; break;
        case "--outstanding-jsonl":
            if (options.hasOutstandingJsonl) return false;
            options.outstandingJsonl = value; options.hasOutstandingJsonl = true; break;
        default: return false;
        }
    }
    return true;
}

/// The effects APIs own path policy and durable operations. Never print their
/// freeform exceptions: they may contain local paths or private sink keys.
int runErrorCommand(string verb, const string[] args) {
    Options options;
    bool valid = parseOptions(args, options);
    if (valid) switch (verb) {
    case "errors-init":
        valid = options.hasJournal && !options.hasFromV1 &&
            !options.hasErrorsJsonl && !options.hasOutstandingJsonl;
        break;
    case "errors-copy":
        valid = options.hasFromV1 && options.hasJournal &&
            !options.hasErrorsJsonl && !options.hasOutstandingJsonl;
        break;
    case "errors-export":
        valid = options.hasJournal && !options.hasFromV1 &&
            (options.hasErrorsJsonl || options.hasOutstandingJsonl);
        break;
    case "errors-verify":
        valid = !options.hasJournal && !options.hasFromV1 &&
            (options.hasErrorsJsonl || options.hasOutstandingJsonl);
        break;
    default: valid = false;
    }
    if (!valid) {
        stderr.writeln("scrubbed: errors-invalid-arguments");
        return 2;
    }
    try {
        switch (verb) {
        case "errors-init": createJournalV3(options.journal); break;
        case "errors-copy": copyV1ToV2(options.fromV1, options.journal); break;
        case "errors-export":
            exportV2(options.journal, options.errorsJsonl, options.outstandingJsonl);
            break;
        case "errors-verify":
            verifyV2Export(options.errorsJsonl, options.outstandingJsonl);
            break;
        default: assert(0);
        }
    } catch (Exception failure) {
        if (failure.msg == "failure journal: v2-sink-label-too-long" ||
            failure.msg == "error export: v2-sink-label-too-long")
            stderr.writeln("scrubbed: v2-sink-label-too-long");
        else stderr.writeln("scrubbed: errors-operation-refused");
        return 2;
    }
    return 0;
}

unittest {
    // A valid flag set, mixing the `--flag value` and `--flag=value`
    // spellings, still parses exactly as before this file's `parseOptions`
    // switched to the shared `effects.cli_option_parsing.nextOption` helper.
    string[] args = ["--journal", "/tmp/journal.v3", "--from-v1=/tmp/v1.jsonl"];
    Options options;
    assert(parseOptions(args, options), "a valid flag set was rejected");
    assert(options.journal == "/tmp/journal.v3" && options.hasJournal);
    assert(options.fromV1 == "/tmp/v1.jsonl" && options.hasFromV1);
}

unittest {
    // Regression for issue #351: before the shared `cli_option_parsing`
    // helper, this file's hand-rolled `parseOptions` was the one of the
    // three copies missing the NUL-byte/empty-value check, and so silently
    // accepted a NUL byte embedded in an option value that
    // `crawl_cli.d`/`metadata_route_cli.d` already rejected. It must now be
    // rejected here too, in both flag spellings.
    string[] spaceForm = ["--journal", "bad\0value"];
    Options rejectedSpaceForm;
    assert(!parseOptions(spaceForm, rejectedSpaceForm),
        "error_cli.d parseOptions accepted a NUL-byte-containing value (--flag value form)");

    string[] equalsForm = ["--journal=bad\0value"];
    Options rejectedEqualsForm;
    assert(!parseOptions(equalsForm, rejectedEqualsForm),
        "error_cli.d parseOptions accepted a NUL-byte-containing value (--flag=value form)");
}

unittest {
    // Empty values were already rejected before this fix (error_cli.d had
    // this half of the check, just not the NUL-byte half); confirm the
    // switch to the shared helper didn't lose it.
    string[] emptyValue = ["--journal="];
    Options rejected;
    assert(!parseOptions(emptyValue, rejected),
        "error_cli.d parseOptions accepted an empty option value");
}
