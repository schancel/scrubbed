/// Release-active source reachability check for the deleted composition predecessor.
module experiments.pipeline_config.predecessor_reachability_check;

import std.algorithm.searching : canFind;
import std.file : SpanMode, dirEntries, exists, readText;
import std.path : buildPath, relativePath;
import std.stdio : writeln;

private void need(bool condition, string message) {
    if (!condition) throw new Exception("predecessor reachability: " ~ message);
}

void main(string[] args) {
    auto root = args.length == 2 ? args[1] : "source";
    need(exists(root), "source root is missing");
    need(!exists(buildPath(root, "stages", "config.d")),
        "source/stages/config.d still exists");

    immutable forbidden = [
        "stages.config", "buildConfigV2", "StagePlan",
        "parseFilterConfig", "loadFilterConfig", "manifestConfig",
        "processOne", "processV2One", "processManifestOne",
        "Pipeline.build(", "Pipeline.buildConfigured",
        "alias FilterOptions =", "alias FilterFactory =", "struct FilterSpec {",
        "alias StreamingFilterFactory =", "registerFilterFactory",
        "registerStreamingFilterFactory", "addFilterFactory",
        "addStreamingFilterFactory"
    ];
    foreach (entry; dirEntries(root, "*.d", SpanMode.depth)) {
        auto source = readText(entry.name);
        foreach (token; forbidden)
            need(!source.canFind(token), relativePath(entry.name, root) ~
                " still reaches " ~ token);
    }
    writeln("predecessor reachability: canonical compiler is the only composition root");
}
