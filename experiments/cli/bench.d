// Build with: ldc2 -O -of=.dub/bench bench.d
// Run with: .dub/bench <baseline executable> <spike executable>
import std.algorithm : sort;
import std.datetime.stopwatch : StopWatch;
import std.process : execute;
import std.stdio : writeln;

long medianMicroseconds(string executable) {
    long[] samples;
    foreach (i; 0 .. 105) {
        StopWatch watch;
        watch.start();
        auto result = execute([executable, "--help"]);
        watch.stop();
        assert(result.status == 0, executable ~ " --help failed");
        if (i >= 5)
            samples ~= watch.peek.total!"usecs";
    }
    samples.sort();
    return samples[samples.length / 2];
}

int main(string[] args) {
    if (args.length != 3) {
        writeln("usage: bench <baseline executable> <spike executable>");
        return 2;
    }
    foreach (executable; args[1 .. $])
        writeln(executable, ": median --help startup (100 samples, 5 warmups) = ",
            medianMicroseconds(executable), " us");
    return 0;
}
