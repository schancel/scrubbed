---
name: codebase-audit
description: Occasionally audit the whole tree for modularity, dead code, earned abstractions, and collapsed seams. Use when asked to audit the codebase, review architecture across modules, find unused code, or look for patterns that should be factored. Emits tickets, not an in-place refactor. Use when the user runs /codebase-audit.
---

# Codebase audit

Feature work never asks whether a module is still reached. A bugfix review never sees the third copy of a helper. Run this skill occasionally, or when asked — not as part of every loop ([eligible work](../../references/queue.md#eligible-work)) — against the whole tree, not against the diff of the ticket in front of you. Load the tracker from [`.agents/binding`](../../references/load-binding.md) before filing.

The questions are in [engineering judgment](../../references/engineering-judgment.md). This skill is how they get asked of code nobody is currently touching. Output is tickets via `$ticket-creation`, ranked later by `$backlog-grooming`. Do not start a refactor in place; an audit that lands a rewrite has become implementation without a contract.

## What to look for

Walk modules, not files. For each subtree that claims to be a boundary (a directory with `AGENTS.md`, a package, a crate, a feature folder):

- **Reached?** Is anything outside still calling this, through the facade it claims? Evidence is references, tests, and generated interface files, not "it looks important." Unreached code becomes a deletion ticket naming the exact symbols and the search that found no callers.
- **Loadable?** Can an agent changing this module work from its code, its instructions, and the *interfaces* of its dependencies — or must it open implementations? If implementations leak, the boundary is fiction; ticket the facade, don't pretend.
- **One home?** Is a fact represented in two places without a stated derived-from relationship?
- **Earned abstraction?** Has the same shape now appeared three times with real tension (call sites that drift, fixes applied to one copy and not the others)? Rule of three is a warning, not a mandate — the ticket should show the three copies and the cost of leaving them. Three calls to a bad `Utils` helper are not an earned abstraction.
- **Nonsense states?** Booleans and strings that can represent combinations the product forbids. Names that are job titles (`Manager`, `Utils`) with no job. Validation sprinkled down a stack instead of parsed at the edge.
- **Collapsed seam?** Was a durable record flattened (boolean for a known enum, string for an identity, one-to-one for a relationship the product already treats as many) in a way that a *currently accepted* next feature would have to migrate? Cite that feature. Hypothetical plugins are not seams.
- **Chunkability?** Functions or types that cannot be held in working memory, globals that couple otherwise independent pieces, directories that import in a cycle.
- **Leftover scaffolding?** Compatibility layers, feature flags, or adapters with no owner, no successor, and no removal trigger.

## What not to look for

- Style, import order, comment tone — unless a consuming repo's `AGENTS.md` says they are load-bearing.
- Speculative "this could be a framework." That is the failure mode this skill exists to avoid.
- Issues already on the tracker. Dedupe; add evidence to the existing item.

## How far to go

An audit is a survey, not a proof of every finding. Each candidate gets:

- the location and the claim ("this is dead", "these three want one interface", "this boolean is the invites hole");
- the cheapest evidence that would falsify it (a caller, a test, a ticket that is *not* actually accepted);
- a suggested ticket title and the draft shape from `$ticket-creation`.

Stop when additional walking would only produce more of the same class already ticketed, or when the user-stated budget is exhausted. Prefer a short list of high-reversal-cost items over a catalog of nits.

Show the draft tickets before publishing. The audit does not claim, implement, or merge.
