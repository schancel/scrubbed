/// Fixed-diagnostic boundary for explicit, opt-in v2 journal commands.
module effects.error_cli;

import effects.failure_journal : createV2, copyV1ToV2;
import effects.durable_job : createJournalV3;
import effects.error_export : exportV2, verifyV2Export;
import std.stdio : stderr;
import std.string : indexOf, startsWith;

private struct Options {
    string journal, fromV1, errorsJsonl, outstandingJsonl;
    bool hasJournal, hasFromV1, hasErrorsJsonl, hasOutstandingJsonl;
}

private bool parseOptions(const string[] args, ref Options options) {
    for (size_t i; i < args.length; ++i) {
        string flag = args[i];
        string value;
        auto equal = flag.indexOf('=');
        if (equal >= 0) {
            value = flag[equal + 1 .. $];
            flag = flag[0 .. equal];
        } else {
            if (i + 1 >= args.length || args[i + 1].startsWith("--")) return false;
            value = args[++i];
        }
        if (!value.length) return false;
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
