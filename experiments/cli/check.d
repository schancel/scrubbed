// Build with: ldc2 -O -of=.dub/check check.d (assertions must remain enabled)
// Run with: .dub/check <baseline executable> <spike executable> <completer executable>
import std.algorithm.searching : canFind;
import std.conv : to;
import std.process : execute;
import std.stdio : writeln;

void expect(string label, string[] command, int status, string fragment) {
    auto result = execute(command);
    assert(result.status == status,
        label ~ ": exit " ~ result.status.to!string ~ " expected " ~ status.to!string);
    assert(result.output.canFind(fragment),
        label ~ ": missing output fragment: " ~ fragment ~ "\n" ~ result.output);
    writeln("ok: ", label);
}

int main(string[] args) {
    if (args.length != 4) {
        writeln("usage: check <baseline> <spike> <completer>");
        return 2;
    }
    auto baseline = args[1];
    auto spike = args[2];
    auto complete = args[3];

    expect("baseline help", [baseline, "--help"], 0, "--list-filters");
    expect("baseline no-verb list", [baseline, "--list-filters"], 0, "registered filters:");
    expect("baseline missing flags", [baseline], 2, "--input and --output are required");

    expect("root help", [spike, "--help"], 0, "Available commands:");
    expect("repair help", [spike, "repair", "--help"], 0, "Required arguments:");
    expect("extract help", [spike, "extract", "--help"], 0, "--format");
    expect("run help", [spike, "run", "--help"], 0, "--list-filters");
    expect("repair alias and typed flag", [spike, "fix", "-i", "in", "-o", "out", "-j", "3"], 0, "Repair(");
    expect("extract alias", [spike, "x", "-i", "in", "-o", "out"], 0, "Extract(");
    expect("legacy no-verb flags", [spike, "--input", "in", "--output", "out", "--threads", "3", "--filters", "normalize-line-endings"], 0, "Run(");
    expect("legacy list flag", [spike, "--list-filters"], 0, "Run(");
    expect("legacy missing flags", [spike], 2, "--input and --output are required");
    expect("missing required flag", [spike, "repair", "--input", "in"], 2, "required");
    expect("invalid typed value", [spike, "repair", "-i", "in", "-o", "out", "-j", "abc"], 2, "converting");
    expect("unknown flag", [spike, "repair", "-i", "in", "-o", "out", "--bogus"], 2, "Unrecognized");
    expect("unknown verb", [spike, "unknown"], 2, "Unrecognized");

    expect("bash setup", [complete, "init", "--bash", "--commandName", "scrubbed"], 0, "complete -C");
    expect("zsh setup", [complete, "init", "--zsh", "--commandName", "scrubbed"], 0, "bashcompinit");
    expect("fish setup", [complete, "init", "--fish", "--commandName", "scrubbed"], 0, "complete -c scrubbed");
    expect("bash command names", [complete, "complete", "--bash", "--", "re"], 0, "repair");
    expect("fish option names", [complete, "complete", "--fish", "--", "repair", "--th"], 0, "--threads");
    auto values = execute([complete, "complete", "--fish", "--", "extract", "--format", ""]);
    assert(values.status == 0 && values.output.canFind("--format") &&
        !values.output.canFind("\ntext\n"), "argument-value completion unexpectedly changed");
    writeln("ok: value completion absent (option names returned instead)");
    writeln("22 checks passed");
    return 0;
}
