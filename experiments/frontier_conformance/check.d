/// Release-mode entry point for the shared frontier conformance suite.
module experiments.frontier_conformance.check;

import domain.job_queue : openInMemoryJobQueue;
import experiments.frontier_conformance.conformance : runConformance;
import std.file : readText;
import std.stdio : writeln;
import std.string : join, lineSplitter;

void main() {
    auto actual = runConformance(&openInMemoryJobQueue);
    auto expectedText = readText(
        "experiments/frontier_conformance/fixtures/v1.expected.tsv");
    string[] expected;
    foreach (line; expectedText.lineSplitter) expected ~= line.idup;
    if (actual != expected)
        throw new Exception("frontier conformance: canonical v1 replay fixture changed\n" ~
            actual.join("\n"));
    writeln("frontier conformance passed: memory backend, v1 canonical replay");
}
