/// Reproducible benchmark driver for the isolated code-routing experiment.
module evaluate;

import core.sys.posix.sys.resource : RUSAGE_SELF, getrusage, rusage;
import core.time : MonoTime;
import evaluation : Fixture, classify, hashBytes, loadManifest, measure;
import std.conv : to;
import std.file : read;
import std.path : buildPath;
import std.stdio : writeln;

private long peakRssBytes()
{
    rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0)
        throw new Exception("getrusage failed");
    version (OSX)
        // Darwin's first opaque long is ru_maxrss, reported in bytes.
        return usage.ru_opaque[0];
    else
        return usage.ru_maxrss * 1024L;
}

int main(string[] arguments)
{
    if (arguments.length < 3 || arguments.length > 4 ||
        (arguments[1] != "baseline" && arguments[1] != "candidate"))
    {
        writeln("usage: evaluate baseline|candidate ROOT [ITERATIONS]");
        return 2;
    }
    const mode = arguments[1];
    const root = arguments[2];
    const iterations = arguments.length == 4 ? arguments[3].to!size_t : 10_000;
    auto fixtures = loadManifest(root);
    string inputDigest;
    foreach (fixture; fixtures)
        inputDigest ~= fixture.sha256;
    inputDigest = hashBytes(cast(const(ubyte)[]) inputDigest);

    size_t routed;
    size_t proxyHits;
    const started = MonoTime.currTime;
    foreach (_; 0 .. iterations)
        foreach (fixture; fixtures)
        {
            if (mode == "baseline")
            {
                auto bytes = cast(ubyte[]) read(buildPath(root, "fixtures", fixture.file));
                if (bytes.length == 0)
                    throw new Exception("empty fixture");
            }
            else
            {
                auto result = measure(root, fixture);
                routed += result.actualRoute;
                proxyHits += result.candidateProxy;
            }
        }
    const elapsedNs = (MonoTime.currTime - started).total!"nsecs";
    writeln(mode, '\t', iterations, '\t', fixtures.length, '\t', inputDigest,
        '\t', elapsedNs, '\t', peakRssBytes(), '\t', routed, '\t', proxyHits);
    return 0;
}
