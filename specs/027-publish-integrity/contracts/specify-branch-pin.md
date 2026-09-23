# Contract: Specify branch pin (US3)

`PhaseRequest.build(feature, :specify, opts)`: the prompt keeps the existing text and appends the branch pin immediately after the `SPECIFY_FEATURE_DIRECTORY` sentence:

```
/speckit.specify Implement the feature specified in <breakdown ref> (id <id>, <slug>).
Use SPECIFY_FEATURE_DIRECTORY=specs/<spec_id>-<slug>.
Use GIT_BRANCH_NAME=feature/<spec_id>-<slug> — that branch already exists and is
checked out: reuse it (allow existing branch); never create or switch to another branch.
Follow the constitution.
```

- The branch string is produced by the same naming as `Worktree.locate/2` (`"feature/#{Feature.spec_id(feature)}-#{slug}"`). There must be one helper, not two literals: `Worktree.branch_name/1`, which `locate/2` also uses.
- There is no change for any other phase.
- The pin is a mitigation. The guarantee is the branch-drift gate (`branch-guard.md`).
