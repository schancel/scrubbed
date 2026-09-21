module module_check_runner;

import check_modules : checkTree;
import std.algorithm.searching : canFind;
import std.process : execute;
import std.stdio : writeln;

private void expectClean(string root) {
    auto failures = checkTree(root);
    assert(failures.length == 0, root ~ ": unexpected failure: " ~ (failures.length ? failures[0] : ""));
}

private void expectFailure(string checker, string root, string moduleName, string rule) {
    auto failures = checkTree(root);
    assert(failures.length > 0, root ~ ": expected a failure");
    bool found;
    foreach (failure; failures)
        if (failure.canFind(moduleName) && failure.canFind(rule)) found = true;
    assert(found, root ~ ": expected module and rule in diagnostic");
    auto result = execute([checker, root]);
    assert(result.status == 1, root ~ ": checker must exit nonzero");
    assert(result.output.canFind(moduleName) && result.output.canFind(rule),
        root ~ ": checker output must name module and rule");
}

void main(string[] args) {
    assert(args.length == 2, "usage: module-check-fixtures <checker-binary>");
    expectClean("tests/module_check/valid");
    auto valid = execute([args[1], "tests/module_check/valid"]);
    assert(valid.status == 0, "valid fixture checker must succeed");
    expectFailure(args[1], "tests/module_check/forbidden_import", "content.extract", "content may import domain, but not app or cli");
    expectFailure(args[1], "tests/module_check/missing_doc", "domain.document", "missing module doc");
    writeln("module check fixtures: ok (valid, forbidden import, missing doc)");
}
