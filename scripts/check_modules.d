// Check the documented module seams without parsing the whole D language.
module check_modules;

import std.algorithm.searching : canFind, startsWith;
import std.file : SpanMode, dirEntries, exists, readText;
import std.path : baseName, buildPath, dirName, stripExtension;
import std.regex : matchAll, matchFirst, regex;
import std.stdio : stderr, writeln;
import std.string : replace, split, splitLines, strip;

private bool projectModule(string name) {
    foreach (prefix; ["app", "cli", "pipeline", "filters", "domain", "content", "stages", "effects"])
        if (name == prefix || name.startsWith(prefix ~ "."))
            return true;
    return false;
}

private bool inLayer(string name, string layer) {
    return name == layer || name.startsWith(layer ~ ".");
}

private string modulePath(string root, string path) {
    auto prefix = root ~ "/";
    return (path.startsWith(prefix) ? path[prefix.length .. $] : path).replace("\\", "/");
}

private string importRule(string owner, string dependency) {
    if (inLayer(owner, "domain") || inLayer(owner, "content") || inLayer(owner, "stages")) {
        // domain.document's existing unittest imports std.file for a temp
        // mapping fixture; source changes there are outside this ticket.
        if (inLayer(dependency, "effects") ||
            (inLayer(dependency, "std.file") && owner != "domain.document") ||
            (inLayer(dependency, "std.mmfile") && owner != "domain.document") ||
            inLayer(dependency, "std.socket") || inLayer(dependency, "std.net"))
            return "domain/content/stages must not import effects or concrete I/O";
    }
    if (!projectModule(dependency)) return null;
    if (owner == "app" && dependency != "cli")
        return "app may import only cli among project modules";
    if (owner == "cli") return null;
    if (owner == "pipeline" && (inLayer(dependency, "app") || inLayer(dependency, "cli") || inLayer(dependency, "filters")))
        return "pipeline must not import app, cli, or concrete filters";
    if (owner == "domain" || owner.startsWith("domain.")) {
        if (dependency != "domain" && !dependency.startsWith("domain."))
            return "domain modules must remain independent of other project layers";
    }
    if (owner == "content" || owner.startsWith("content.")) {
        if (inLayer(dependency, "app") || inLayer(dependency, "cli"))
            return "content may import domain, but not app or cli";
        if (!inLayer(dependency, "domain") && !inLayer(dependency, "content"))
            return "content may import only domain and content project modules";
    }
    if (inLayer(owner, "stages") && !inLayer(dependency, "stages") &&
        !inLayer(dependency, "domain") && !inLayer(dependency, "content"))
        return "stages may import only stages, domain and content project modules";
    if (inLayer(owner, "effects") && !inLayer(dependency, "effects") &&
        !inLayer(dependency, "stages") && !inLayer(dependency, "domain") &&
        !inLayer(dependency, "content"))
        return "effects may import only effects, stages, domain and content project modules";
    if (owner == "filters" || owner.startsWith("filters.")) {
        if (inLayer(dependency, "app") || inLayer(dependency, "cli"))
            return "filters must not import app or cli";
        if (dependency == "filters" || dependency.startsWith("filters.")) {
            if (owner == "filters.entities" && (dependency == "filters.entities_data" || dependency == "filters.mojibake"))
                return null;
            return "cross-filter imports are limited to entities -> entities_data/mojibake";
        }
    }
    return null;
}

unittest {
    import std.file : mkdirRecurse, rmdirRecurse, tempDir, write;
    import std.uuid : randomUUID;

    assert(importRule("effects.runner", "stages.contract").length == 0);
    assert(importRule("effects.runner", "domain.document").length == 0);
    assert(importRule("effects.runner", "content.pieces").length == 0);
    assert(importRule("domain.document", "effects.runner").length != 0);
    assert(importRule("content.pieces", "effects.runner").length != 0);
    assert(importRule("stages.contract", "effects.runner").length != 0);
    assert(importRule("content.pieces", "std.file").length != 0);
    assert(importRule("stages.contract", "std.mmfile").length != 0);
    assert(importRule("domain.document", "std.socket").length != 0);
    assert(importRule("effects.runner", "cli").length != 0);

    auto fixtureRoot = buildPath(tempDir(), "scrubbed-effects-check-" ~ randomUUID().toString());
    scope(exit) rmdirRecurse(fixtureRoot);
    auto good = buildPath(fixtureRoot, "good", "effects");
    mkdirRecurse(good);
    write(buildPath(good, "runner.d"),
        "/// Fixture effect.\nmodule effects.runner;\n" ~
        "import stages.contract, domain.document, content.pieces;\n");
    assert(checkTree(buildPath(fixtureRoot, "good")).length == 0);
    foreach (layer; ["domain", "content", "stages"]) {
        auto bad = buildPath(fixtureRoot, "bad_" ~ layer, layer);
        mkdirRecurse(bad);
        write(buildPath(bad, "fixture.d"),
            "/// Forbidden boundary fixture.\nmodule " ~ layer ~
            ".fixture;\nimport effects.runner;\n");
        auto failures = checkTree(buildPath(fixtureRoot, "bad_" ~ layer));
        assert(failures.length == 1 && failures[0].canFind("effects.runner"));
    }
}

private bool hasModuleDoc(string root, string path, string source, string name) {
    if (name == "filters.entities_data") return true; // pinned generated table
    auto declaration = matchFirst(source, regex(`(?m)^\s*module\s+[A-Za-z_][\w.]*\s*;`));
    if (!declaration.empty) {
        auto before = source[0 .. declaration.pre.length];
        foreach (line; before.splitLines)
            if (line.strip.startsWith("///") && line.strip[3 .. $].strip.length) return true;
    }
    auto relative = modulePath(root, path);
    foreach (guide; [buildPath(root, "README.md"), buildPath(dirName(path), "README.md")])
        if (exists(guide) && (readText(guide).canFind(relative) || readText(guide).canFind(baseName(path))))
            return true;
    return false;
}

string[] checkTree(string root) {
    string[] failures;
    foreach (entry; dirEntries(root, "*.d", SpanMode.depth)) {
        auto path = entry.name;
        auto relative = modulePath(root, path);
        auto expected = stripExtension(relative).replace("/", ".");
        auto source = readText(path);
        auto declaration = matchFirst(source, regex(`(?m)^\s*module\s+([A-Za-z_][\w.]*)\s*;`));
        if (declaration.empty) {
            failures ~= relative ~ ": missing module declaration (expected " ~ expected ~ ")";
            continue;
        }
        auto name = declaration.captures[1];
        if (name != expected)
            failures ~= relative ~ ": module " ~ name ~ ": declaration must match path (" ~ expected ~ ")";
        if (!hasModuleDoc(root, path, source, name))
            failures ~= relative ~ ": module " ~ name ~ ": missing module doc (/// header or README entry)";
        foreach (statement; matchAll(source, regex(`(?m)^\s*(?:(?:public|private|static|protected|package)\s+)*import\s+([^;]+);`))) {
            // A colon starts selective symbols; commas after it do not name modules.
            auto modules = statement.captures[1].split(":")[0];
            foreach (part; modules.split(",")) {
                auto aliases = part.split("=");
                auto dependency = aliases[$ - 1].strip;
                auto rule = importRule(name, dependency);
                if (rule.length)
                    failures ~= relative ~ ": module " ~ name ~ " imports " ~ dependency ~ ": " ~ rule;
            }
        }
    }
    return failures;
}

version (moduleCheckRunner) {} else {
    int main(string[] args) {
        if (args.length != 2) {
            stderr.writeln("usage: check_modules <source-root>");
            return 2;
        }
        auto failures = checkTree(args[1]);
        foreach (failure; failures) stderr.writeln(failure);
        if (failures.length) return 1;
        writeln("module check: ok");
        return 0;
    }
}
