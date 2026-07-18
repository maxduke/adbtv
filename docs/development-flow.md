# Development Flow

ADB TV uses small, reviewable branches and git worktrees for feature work.

## Principles

- Keep `main` clean and releasable.
- Do feature work in a separate worktree on a topic branch.
- Merge changes through a pull request after required checks pass.
- Commit planning, protocol, UI, and CI changes separately when possible.
- Do not mix unrelated refactors with feature work.
- Do not commit secrets, provisioning profiles, private certificates, or local signing material.

## Recommended Worktree Layout

Keep the main checkout and feature worktrees as siblings:

```sh
/home/maxduke/projects/adbtv
/home/maxduke/projects/adbtv-worktrees/protocol-spike
/home/maxduke/projects/adbtv-worktrees/ios-ci
```

When using Codex, start the Codex session from the feature worktree or make that worktree an allowed writable root. A sibling worktree is the preferred Git layout, but Codex cannot safely edit it unless the session has write access to that path.

## Starting Work

From the main checkout:

```sh
git status --short
git switch main
git pull --ff-only
git worktree add ../adbtv-worktrees/protocol-spike -b protocol-spike
```

Then work from the new directory:

```sh
cd ../adbtv-worktrees/protocol-spike
```

## Finishing Work

In the feature worktree:

```sh
git status --short
git add <files>
git commit -m "Implement protocol spike foundation"
git push -u origin protocol-spike
```

After the branch is merged and no longer needed:

```sh
git worktree remove ../adbtv-worktrees/protocol-spike
git branch -d protocol-spike
```

## Branch Naming

Use short purpose-based names:

- `protocol-spike`
- `ios-ci`
- `device-discovery`
- `apk-install`
- `tv-remote-actions`

## Commit Style

Use imperative messages:

- `Document initial architecture`
- `Add ADB packet framing tests`
- `Implement Bonjour discovery`
- `Add simulator CI workflow`

## Main Branch Protection

The GitHub `main` branch requires:

- a pull request, with no separate approval required for the solo maintainer;
- an up-to-date passing **SwiftPM Tests** check;
- an up-to-date passing **iOS Simulator Build** check;
- resolved review conversations;
- linear history;
- no force-pushes or branch deletion.

Unsigned IPA packaging and portrait snapshots are manual release-candidate checks. Release tags package the final IPA automatically.

## GitHub Actions Supply Chain

Workflow actions are pinned to full upstream commit SHAs. Keep the adjacent major-version
comment, such as `# v7`, so Dependabot can continue proposing readable updates. Before
accepting an action update, verify that the proposed commit is the commit referenced by the
intended upstream tag and let the pull-request workflows resolve the pinned action successfully.

Repository settings require full-length action SHAs. Do not replace a pinned commit with a
mutable branch or tag reference.
