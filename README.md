# herdr-hub-worktrees

Mirror a [Herdr](https://github.com/herdrdev/herdr) worktree into every nested sub-repo of a
project hub.

A hub repo (the `ws-project-hub` layout) tracks docs and tooling, and git-ignores the sub-repo
clones that sit beside them:

```text
talkyto-project/            # hub repo
  talkyto-firebase-backend/ # separate clone, git-ignored by the hub
  talkyto-business-backend/ # separate clone, git-ignored by the hub
  talkyto-marketing/
  talkyto-mobile-app/
```

`herdr worktree create` checks out the hub alone, so a fresh lane has no sub-repos at all — the
place where the actual code lives is missing. This plugin gives every lane a matching worktree of
each nested clone, on one branch named after the lane, and takes them away again when the lane
goes.

## Install

Requires Herdr 0.7.5 or newer.

```sh
herdr plugin link /path/to/herdr-hub-worktrees
```

`git`, `jq`, and Herdr 0.7.5+ are the only requirements. Publish the directory as a GitHub repo
tagged `herdr-plugin` to install it with `herdr plugin install <owner>/<repo>` instead.

## What it does

Event hooks, automatic:

|Event|Result|
|---|---|
|`worktree.created`|adds `<lane>/<sub-repo>` for every nested clone, on branch `<hub lane branch>`|
|`worktree.opened`|same, idempotent — heals a lane whose sub-repo worktrees were pruned|
|`worktree.removed`|removes/prunes the sub-repo worktrees that this lane owned|

Workspace actions, manual (right-click a workspace):

|Action|Result|
|---|---|
|Sub-repo worktrees: create|the `sync` pass, on demand|
|Sub-repo worktrees: remove|prunes the lane's sub-repo worktrees, refusing any with uncommitted work|
|Sub-repo worktrees: remove (discard changes)|the same with `--force`|

The lane branch is the hub worktree's branch (`worktree/silver-harbor-fce7`), or the lane directory
name when the hub worktree is detached. A sub-repo that already has that branch checked out
somewhere is left alone (`keep:`), never re-pointed.

State lives in `$HERDR_PLUGIN_STATE_DIR/lanes/<encoded lane path>`, recording the hub root and each
path this plugin created. It is what makes pruning safe after Herdr has already deleted the lane
directory, and it is deleted once the lane is fully cleaned up.

## Safety

- **A lane is never the hub main checkout.** `sync` refuses a context that is not a linked
  worktree; `prune` refuses one whose lane path equals the hub root. Without that second guard a
  workspace with no worktree resolves to the hub root and the prune loop walks the *main* checkout,
  where it would delete the long-lived sub-repo worktrees standing beside the clones.
- **A lane must belong to this hub.** `sync` compares `git rev-parse --git-common-dir` of the lane
  against `<hub root>/.git`, so a foreign repository never receives this hub's sub-repos.
- **Only recorded paths are removed.** When the state file survives, it is the whitelist: a
  checkout inside the lane directory that this plugin did not create is reported `keep: … not
  recorded for this lane` and left in place.
- **Uncommitted work wins.** Plain `prune` reports `keep: … has uncommitted work` and returns
  success; only the explicit force action discards it.
- **Branches are never deleted**, exactly like Herdr leaves the hub lane branch behind.

Every invocation prints one verdict line per path — `add:`, `keep:`, `remove:`, `prune:`, `fail:`,
or `skip:` — plus a `done:` tally. Herdr captures stdout into the plugin log
(`herdr plugin log list --plugin klukacin.hub-worktrees`); read the lines, not the exit code, since
a refusal is a success.

## Caveats

- Sub-repos are detected as directories under the hub root holding a real `.git` **directory**
  (a primary clone). Nested linked worktrees are skipped, so the pre-existing
  `<sub-repo>-<topic>/` checkouts in a hub are never treated as clones.
- Uncommitted work in a lane's sub-repo blocks lane teardown by design: `herdr worktree remove`
  deletes the hub directory anyway, and the following prune keeps the registration so the branch
  and the commit graph stay reachable.

## License

MIT
