// D-only exact-output target for the changed-executable attribution control.
module pipeline_attestation_check;

import std.file : read, write;
import std.stdio : writeln;

version (AttestationVariantA) enum variantIdentity = "attestation-variant-a";
else version (AttestationVariantB) enum variantIdentity = "attestation-variant-b";
else static assert(false, "build one explicit attestation variant");

int main(string[] args) {
    if (args.length == 2 && args[1] == "--identity") {
        writeln(variantIdentity);
        return 0;
    }
    if (args.length != 3) return 2;
    auto input = cast(const(ubyte)[]) read(args[1]);
    ubyte[] output;
    output.reserve(input.length);
    size_t index;
    while (index < input.length) {
        if (input[index] == '\r') {
            output ~= cast(ubyte) '\n';
            if (index + 1 < input.length && input[index + 1] == '\n') ++index;
        } else {
            output ~= input[index];
        }
        ++index;
    }
    write(args[2], output);
    return 0;
}
