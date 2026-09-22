/// Strict v2 document-stage configuration boundary; not connected to the CLI.
module stages.config;

import stages.contract : StageDeclaration, StageTransform;
import stages.registry : OptionType, StageOption, StageOptions, StageRegistry,
    availableStages;
import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;

struct ConfiguredStage {
    const(StageDeclaration) declaration;
    StageTransform transform;
    StageOptions options;
}

struct StagePlan {
    ConfiguredStage[] stages;
}

private void exactKeys(JSONValue value, const(string)[] allowed, string context) {
    enforce(value.type == JSONType.object, context ~ " must be an object");
    foreach (key, ignored; value.object) {
        bool known;
        foreach (candidate; allowed)
            if (key == candidate) known = true;
        enforce(known, "unknown " ~ context ~ " key: " ~ key);
    }
}

/// Parse and resolve every stage before any document is evaluated.
StagePlan buildConfigV2(string json, const(StageRegistry)* registry = null) {
    if (registry is null) registry = availableStages();
    auto root = parseJSON(json);
    exactKeys(root, ["version", "stages"], "config");
    enforce(("version" in root.object) !is null, "missing config version");
    enforce(root["version"].type == JSONType.integer && root["version"].integer == 2,
        "config version must be integer 2");
    enforce(("stages" in root.object) !is null, "missing stages");
    enforce(root["stages"].type == JSONType.array, "stages must be an array");
    StagePlan plan;
    bool[string] seen;
    foreach (entry; root["stages"].array) {
        exactKeys(entry, ["name", "options"], "stage");
        enforce(("name" in entry.object) !is null &&
            entry["name"].type == JSONType.string, "stage name must be text");
        auto name = entry["name"].str;
        auto registration = registry.find(name);
        enforce(registration !is null, "unknown stage: " ~ name);
        enforce((name in seen) is null, "duplicate configured stage: " ~ name);
        seen[name] = true;
        StageOptions options;
        if (("options" in entry.object) !is null) {
            auto raw = entry["options"];
            enforce(raw.type == JSONType.object, "stage options must be an object");
            foreach (key, value; raw.object) {
                bool found;
                foreach (declared; registration.options) {
                    if (declared.key != key) continue;
                    found = true;
                    final switch (declared.type) {
                    case OptionType.text:
                        enforce(value.type == JSONType.string, "option " ~ key ~ " must be text");
                        options[key] = StageOption.text(value.str);
                        break;
                    case OptionType.integer:
                        enforce(value.type == JSONType.integer, "option " ~ key ~ " must be integer");
                        options[key] = StageOption.integer(value.integer);
                        break;
                    case OptionType.boolean:
                        enforce(value.type == JSONType.true_ || value.type == JSONType.false_,
                            "option " ~ key ~ " must be boolean");
                        options[key] = StageOption.boolean(value.type == JSONType.true_);
                        break;
                    }
                }
                enforce(found, "unknown option for " ~ name ~ ": " ~ key);
            }
        }
        auto transform = registry.build(name, options);
        plan.stages ~= ConfiguredStage(registration.declaration, transform, options);
    }
    string[] keys;
    foreach (stage; plan.stages) keys ~= stage.declaration.key;
    registry.validateOrder(keys);
    return plan;
}

unittest {
    import stages.fixture; // The fixture's module constructor owns its registration.
    import stages.contract : DecisionKind, PassMode, ResourceDeclaration,
        StageDecision, StageDocument;
    import stages.registry : OptionDeclaration, StageRegistration;
    // Enforce keeps these boundary checks active in release tests.
    void mustReject(string input, const(StageRegistry)* registry = null) {
        bool rejected;
        try buildConfigV2(input, registry);
        catch (Exception) rejected = true;
        enforce(rejected, "invalid v2 config was accepted");
    }

    auto global = buildConfigV2(`{"version":2,"stages":[{"name":"fixture",` ~
        `"options":{"suffix":"rejected","enabled":true}}]}`);
    enforce(global.stages.length == 1 && global.stages[0].declaration.key == "fixture");
    enforce(global.stages[0].transform(StageDocument.init).kind == DecisionKind.reject);
    mustReject(`{"version":2,"stages":[{"name":"fixture-later",` ~
        `"options":{"suffix":"x"}},{"name":"fixture",` ~
        `"options":{"suffix":"x"}}]}`);
    mustReject(`{"version":2,"stages":[{"name":"missing"}]}`);
    mustReject(`{"version":2,"stages":[{"name":"fixture"}]}`);
    mustReject(`{"version":2,"stages":[{"name":"fixture",` ~
        `"options":{"suffix":1}}]}`);
    mustReject(`{"version":2,"stages":[{"name":"fixture",` ~
        `"options":{"suffix":"x","enabled":"true"}}]}`);
    mustReject(`{"version":2,"stages":[{"name":"fixture",` ~
        `"options":{"suffix":"x","unknown":0}}]}`);
    mustReject(`{"version":2,"stages":[{"name":"fixture",` ~
        `"options":[]}]}`);
    mustReject(`{"version":2,"stages":[{"name":"fixture",` ~
        `"unexpected":0,"options":{"suffix":"x"}}]}`);
    mustReject(`{"version":2,"stages":[{"name":"fixture",` ~
        `"options":{"suffix":"x"}},{"name":"fixture",` ~
        `"options":{"suffix":"x"}}]}`);
    foreach (bad; [`{"version":1,"stages":[]}`, `{"version":"2","stages":[]}`,
            `{"version":2.0,"stages":[]}`, `{"version":2,"stages":[],"x":1}`,
            `{"version":2,"stages":{}}`, `{"version":2}`, `{"stages":[]}`,
            `{"version":2,"stages":["fixture"]}`,
            `{"version":2,"stages":[{"name":3}]}`])
        mustReject(bad);

    StageRegistry isolated;
    auto simple = (const ref StageOptions options) {
        return cast(typeof(global.stages[0].transform)) ((StageDocument input) {
            return StageDecision.map(input);
        });
    };
    isolated.add(StageRegistration(StageDeclaration("early", PassMode.singlePass,
        ResourceDeclaration(1, 0)), null, ["late"], null, simple));
    auto typed = (const ref StageOptions options) {
        auto count = options["count"].asInteger();
        auto active = options["active"].asBoolean();
        return cast(typeof(global.stages[0].transform)) ((StageDocument input) {
            if (count == 4 && active) return StageDecision.reject("typed values arrived");
            return StageDecision.map(input);
        });
    };
    isolated.add(StageRegistration(StageDeclaration("late", PassMode.singlePass,
        ResourceDeclaration(1, 0)), [OptionDeclaration("count", OptionType.integer, true),
        OptionDeclaration("active", OptionType.boolean, true)],
        null, ["early"], typed));
    auto valid = buildConfigV2(`{"version":2,"stages":[{"name":"early"},` ~
        `{"name":"late","options":{"count":4,"active":true}}]}`, &isolated);
    enforce(valid.stages.length == 2);
    bool controlFailed;
    try mustReject(`{"version":2,"stages":[]}`, &isolated);
    catch (Exception) controlFailed = true;
    enforce(controlFailed, "negative-test helper did not fail on valid input");
    enforce(valid.stages[1].transform(StageDocument.init).kind == DecisionKind.reject,
        "typed integer and boolean values did not reach the factory");
    auto falseFlag = buildConfigV2(`{"version":2,"stages":[{"name":"late",` ~
        `"options":{"count":4,"active":false}}]}`, &isolated);
    enforce(falseFlag.stages[0].transform(StageDocument.init).kind == DecisionKind.map,
        "typed false boolean value did not reach the factory");
    mustReject(`{"version":2,"stages":[{"name":"late",` ~
        `"options":{"count":4,"active":true}},{"name":"early"}]}`, &isolated);
    mustReject(`{"version":2,"stages":[{"name":"late",` ~
        `"options":{"count":true,"active":true}}]}`, &isolated);
    mustReject(`{"version":2,"stages":[{"name":"late"}]}`, &isolated);
    isolated.add(StageRegistration(StageDeclaration("orphan", PassMode.singlePass,
        ResourceDeclaration(1, 0)), null, ["not-registered"], null, simple));
    mustReject(`{"version":2,"stages":[{"name":"orphan"}]}`, &isolated);
}
