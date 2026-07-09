# Development Flow

ADB TV uses small, reviewable branches and git worktrees for feature work.

## Principles

- Keep `main` clean and releasable.
- Do feature work in a separate worktree on a topic branch.
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
