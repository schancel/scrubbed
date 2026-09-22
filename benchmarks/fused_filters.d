/// Exact-output microbenchmark for runtime-composed scalar-filter fusion.
module fused_filters;

import filters.normalize : normalizeLineEndingsFilter, stripControlCharsFilter;
import filters.punctuation : uncurlQuotesFilter;
import pipeline : Pipeline;
import std.array : appender;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.digest : toHexString;
import std.digest.sha : sha256Of;
import std.json : JSONValue;
import std.stdio : writeln;

private string legacy(string text) {
    return uncurlQuotesFilter(stripControlCharsFilter(
        normalizeLineEndingsFilter(text)));
}

void main() {
    auto builder = appender!string();
    foreach (_; 0 .. 131_072)
        builder.put("“alpha”\r\nbe\0ta\r‘gamma’\n");
    const input = builder.data;
    auto pipeline = Pipeline.build(["normalize-line-endings", "strip-control",
        "uncurl-quotes"]);
    const expected = legacy(input);
    if (pipeline.run(input) != expected)
        throw new Exception("fused and legacy outputs differ");

    JSONValue[] samples;
    foreach (name; ["legacy", "fused", "fused", "legacy", "legacy", "fused"]) {
        auto watch = StopWatch(AutoStart.yes);
        string output;
        foreach (_; 0 .. 5)
            output = name == "legacy" ? legacy(input) : pipeline.run(input);
        watch.stop();
        if (output != expected) throw new Exception(name ~ " output changed");
        samples ~= JSONValue([
            "implementation": JSONValue(name),
            "rounds": JSONValue(5),
            "wall_seconds": JSONValue(cast(double) watch.peek.total!"nsecs" /
                1_000_000_000),
            "exact_output": JSONValue(true)]);
    }

    writeln(JSONValue([
        "schema": JSONValue("scrubbed-fused-filters-v1"),
        "fixture": JSONValue("131072 repeated mixed CRLF/control/curly-quote rows"),
        "input_bytes": JSONValue(cast(long) input.length),
        "output_bytes": JSONValue(cast(long) expected.length),
        "output_sha256": JSONValue(toHexString(sha256Of(expected)).to!string),
        "samples": JSONValue(samples)]).toString);
}

import std.conv : to;
