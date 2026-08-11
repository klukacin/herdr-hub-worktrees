#!/bin/sh
# Herdr hook: mirror a hub worktree into every nested sub-repo.
#
#   mirror.sh sync            worktree.created / worktree.opened / action "sync"
#   mirror.sh prune [--force] worktree.removed / action "prune" / "prune-force"
#   mirror.sh status          action "status" — read-only, before you close a lane
#
# Context arrives through the environment, never argv:
#   HERDR_PLUGIN_EVENT_JSON    event envelope   (event hooks)
#   HERDR_PLUGIN_CONTEXT_JSON  invocation ctx   (actions)
#   HERDR_PLUGIN_STATE_DIR     durable state, keyed by hub worktree path
#
# Herdr captures stdout into the plugin log, so every line printed here is a
# verdict and every exit path prints one. The exit code only says whether the
# hook itself ran; read the log lines for what it decided.

set -u

mode=${1:-sync}
force=${2:-}

say() { printf '%s\n' "$*"; }

command -v git >/dev/null 2>&1 || { say "fail: git not in PATH"; exit 1; }
command -v jq >/dev/null 2>&1 || { say "fail: jq not in PATH"; exit 1; }

# ── resolve the lane: hub worktree path + hub main checkout ──────────────────
lane=""    # the linked hub checkout that was created/opened/removed
root=""    # the hub's main checkout, where the sub-repo clones live
linked=""

ev=${HERDR_PLUGIN_EVENT_JSON:-}
ctx=${HERDR_PLUGIN_CONTEXT_JSON:-}

if [ -n "$ev" ]; then
	lane=$(printf '%s' "$ev" | jq -r '.data.worktree.path // empty')
	root=$(printf '%s' "$ev" | jq -r '.data.workspace.worktree.repo_root // empty')
	linked=$(printf '%s' "$ev" | jq -r '.data.worktree.is_linked_worktree // empty')
fi
if [ -z "$lane" ] && [ -n "$ctx" ]; then
	lane=$(printf '%s' "$ctx" | jq -r '.worktree.checkout_path // empty')
	root=$(printf '%s' "$ctx" | jq -r '.worktree.repo_root // empty')
	linked=$(printf '%s' "$ctx" | jq -r '.worktree.is_linked_worktree // empty')
fi

[ -n "$lane" ] || { say "skip: no worktree in context"; exit 0; }

# Git reports physical paths (/private/tmp/…), Herdr passes the path the user
# typed (/tmp/…). Compare and record physical paths only, or a hub reached
# through a symlink never matches its own worktrees. The leaf may already be
# deleted when prune runs, so resolve the deepest existing ancestor and keep
# the tail — the state key has to stay identical across sync and prune.
physical() {
	p=$1 tail=
	while [ -n "$p" ] && [ "$p" != / ] && [ ! -d "$p" ]; do
		tail=$(basename "$p")${tail:+/$tail}
		p=$(dirname "$p")
	done
	p=$(cd "$p" 2>/dev/null && pwd -P) || { printf '%s' "$1"; return; }
	printf '%s' "$p${tail:+/$tail}"
}

lane=$(physical "$lane")
[ -z "$root" ] || root=$(physical "$root")

state_dir=${HERDR_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/herdr-hub-worktrees}
mkdir -p "$state_dir/lanes" 2>/dev/null || true
state=$state_dir/lanes/$(printf '%s' "$lane" | tr '/' '%')

# A primary clone carries a .git DIRECTORY; a linked worktree carries a .git
# FILE. Only primary clones are mirrored — the rest are transient checkouts of
# the very same repos.
is_primary() { [ -d "$1/.git" ]; }

wt_add() { # sub target branch
	if git -C "$1" show-ref --verify --quiet "refs/heads/$3"; then
		git -C "$1" worktree add "$2" "$3" 2>&1
	else
		git -C "$1" worktree add -b "$3" "$2" HEAD 2>&1
	fi
}

flat() { printf '%s' "$1" | tr '\n' ' '; }

do_sync() {
	[ "$linked" = "true" ] || { say "skip: not a linked worktree: $lane"; exit 0; }
	[ -d "$lane" ] || { say "skip: worktree path is gone: $lane"; exit 0; }
	[ -n "$root" ] || { say "fail: no hub repo_root in context for $lane"; exit 1; }
	[ "$root" != "$lane" ] || { say "skip: that is the main checkout"; exit 0; }

	# The lane must be a checkout of the hub repo itself. A stray context that
	# names some other repository must not receive this hub's sub-repos.
	common=$(git -C "$lane" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
	case $common in
	"$root"/.git | "$root"/.git/) ;;
	*)
		say "skip: $lane is not a checkout of $root"
		exit 0
		;;
	esac

	# One branch name identifies the lane across every repo. Detached hub
	# worktree -> fall back to the worktree directory name.
	branch=$(git -C "$lane" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
	[ -n "$branch" ] || branch=$(basename "$lane")

	say "lane: $lane"
	say "root: $root"
	say "branch: $branch"

	# The record is load-bearing: prune removes only what is listed here, so a
	# record that cannot be written has to be reported, never swallowed.
	fresh=$state.$$
	if ! printf 'root %s\nbranch %s\n' "$root" "$branch" > "$fresh" 2>/dev/null; then
		say "fail: cannot write lane record $state — teardown will not remove anything"
		rm -f "$fresh" 2>/dev/null || true
		fresh=/dev/null
	fi

	added=0 kept=0 failed=0
	for d in "$root"/*/; do
		[ -d "$d" ] || continue
		sub=${d%/}
		name=$(basename "$sub")
		is_primary "$sub" || continue
		target=$lane/$name

		if [ -e "$target" ]; then
			say "keep: $name already present"
			kept=$((kept + 1))
			printf 'wt %s\n' "$target" >> "$fresh"
			continue
		fi
		if out=$(wt_add "$sub" "$target" "$branch"); then
			say "add: $name -> $target [$branch]"
			added=$((added + 1))
			printf 'wt %s\n' "$target" >> "$fresh"
		else
			say "fail: $name: $(flat "$out")"
			failed=$((failed + 1))
		fi
	done

	if [ "$fresh" != /dev/null ] && ! mv "$fresh" "$state" 2>/dev/null; then
		say "fail: cannot save lane record $state — reopen the worktree before removing it"
		rm -f "$fresh" 2>/dev/null || true
	fi
	say "done: added=$added kept=$kept failed=$failed"
	[ "$added" -gt 0 ] || [ "$kept" -gt 0 ] || say "note: no primary sub-repo clones under $root"
}

do_prune() {
	# The hub worktree is usually already deleted by the time worktree.removed
	# fires, so the recorded lane state is the only reliable source of the hub
	# root at that point.
	if [ -z "$root" ] && [ -f "$state" ]; then
		root=$(sed -n 's/^root //p' "$state" | head -1)
	fi
	[ -n "$root" ] || { say "skip: unknown hub root for $lane"; exit 0; }

	# Refuse the hub main checkout. A context without a worktree resolves the
	# lane to the hub root, and the loop below would then walk the root and
	# delete the long-lived sub-repo worktrees that live beside the clones.
	if [ "$lane" = "$root" ]; then
		say "skip: that is the hub main checkout, not a lane: $root"
		exit 0
	fi

	# The contract: this plugin removes only what it recorded. Without a record
	# there is no verdict to make. This is what keeps a context that resolves to
	# a CONTAINER of real checkouts — the hub main checkout, the lanes parent
	# directory, any ancestor — from prefix-matching every worktree below it.
	# Cost of the gate: a lane whose record was lost strands its sub-repo
	# worktrees until it is reopened (sync rewrites the record). Recoverable,
	# which mass deletion is not.
	if [ ! -f "$state" ]; then
		say "skip: no sync record for $lane — this plugin created nothing here"
		say "note: reopen the worktree to re-record it, then remove again"
		exit 0
	fi

	say "lane: $lane"
	say "root: $root"
	[ -n "$force" ] && say "mode: force"

	removed=0 pruned=0 dirty=0 failed=0 foreign=0
	list=$(mktemp "${TMPDIR:-/tmp}/hubwt.XXXXXX") || { say "fail: mktemp"; exit 1; }
	for d in "$root"/*/; do
		[ -d "$d" ] || continue
		sub=${d%/}
		name=$(basename "$sub")
		is_primary "$sub" || continue

		git -C "$sub" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' > "$list"
		while IFS= read -r p; do
			# Only checkouts inside this lane directory are ever touched.
			case $p in
			"$lane"/*) ;;
			*) continue ;;
			esac
			# The record is the whitelist: a checkout this plugin did not
			# create stays put, even under force.
			if ! grep -qxF "wt $p" "$state"; then
				say "keep: $name $p not recorded for this lane"
				foreign=$((foreign + 1))
				continue
			fi
			if [ -d "$p" ]; then
				if [ -n "$force" ]; then
					out=$(git -C "$sub" worktree remove --force "$p" 2>&1)
					rc=$?
				else
					out=$(git -C "$sub" worktree remove "$p" 2>&1)
					rc=$?
				fi
				if [ "$rc" -eq 0 ]; then
					say "remove: $name $p"
					removed=$((removed + 1))
				else
					case $out in
					*"contains modified or untracked files"*)
						say "keep: $name $p has uncommitted work — commit, stash, or use force"
						dirty=$((dirty + 1))
						;;
					*)
						say "fail: $name $p: $(flat "$out")"
						failed=$((failed + 1))
						;;
					esac
				fi
			else
				say "prune: $name $p (stale)"
				pruned=$((pruned + 1))
			fi
		done < "$list"
		git -C "$sub" worktree prune 2>/dev/null || true
	done
	rm -f "$list"

	if [ "$dirty" -eq 0 ] && [ "$failed" -eq 0 ]; then
		rm -f "$state"
	fi
	say "done: removed=$removed pruned=$pruned kept_dirty=$dirty kept_foreign=$foreign failed=$failed"
	say "note: lane branches are left in place, exactly like Herdr leaves the hub branch"
}

# Hooks always arrive too late: Herdr deletes the lane directory first and only
# then fires `worktree.removed`. Nothing this plugin can register will stop a
# removal, and the hub's .gitignore hides the sub-repo checkouts from git, so
# `worktree remove` without --force sees a clean lane and proceeds. This report
# is the only pre-close look at what a lane is holding.
do_status() {
	[ -n "$root" ] || { say "fail: no hub repo_root in context for $lane"; exit 1; }
	[ "$root" != "$lane" ] || { say "skip: that is the hub main checkout, not a lane"; exit 0; }

	subs=0 checkouts=0 files=0 unpushed=0
	say "lane: $lane"
	for d in "$root"/*/; do
		[ -d "$d" ] || continue
		sub=${d%/}
		name=$(basename "$sub")
		is_primary "$sub" || continue
		subs=$((subs + 1))

		git -C "$sub" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' |
			while IFS= read -r p; do
				case $p in
				"$lane"/*) ;;
				*) continue ;;
				esac
				[ -d "$p" ] || { say "$name: checkout is gone: $p"; continue; }

				dirty=$(git -C "$p" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
				br=$(git -C "$p" symbolic-ref --quiet --short HEAD 2>/dev/null || echo '(detached)')
				up=$(git -C "$p" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
				if [ -n "$up" ]; then
					ahead=$(git -C "$p" rev-list --count "$up"..HEAD 2>/dev/null || echo '?')
					where="$ahead ahead of $up"
				else
					where='no upstream, local only'
				fi
				if [ -f "$state" ] && grep -qxF "wt $p" "$state"; then own=mine; else own=foreign; fi
				say "$name: $br — $dirty uncommitted, $where [$own]"
				# The subshell of a pipeline cannot raise the outer counters,
				# so the tallies are recomputed below from the same walk.
			done
	done

	checkouts=$(
		for d in "$root"/*/; do
			sub=${d%/}
			is_primary "$sub" || continue
			git -C "$sub" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
		done | grep -c "^$lane/" || true
	)
	files=$(
		for d in "$root"/*/; do
			sub=${d%/}
			is_primary "$sub" || continue
			git -C "$sub" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p'
		done | grep "^$lane/" | while IFS= read -r p; do
			[ -d "$p" ] && git -C "$p" status --porcelain 2>/dev/null
		done | wc -l | tr -d ' '
	)

	say "status: subrepos=$subs checkouts=$checkouts uncommitted_files=$files"
	if [ "${files:-0}" -gt 0 ]; then
		say "warning: closing this lane deletes those $files files. Herdr will not"
		say "warning: refuse, because the hub ignores the sub-repo directories and"
		say "warning: therefore reports the lane as clean. Commit or stash first."
	fi
	say "note: committed work always survives on the lane branch in each sub-repo"
}

case $mode in
sync) do_sync ;;
prune) do_prune ;;
status) do_status ;;
*)
	say "fail: unknown mode '$mode' (sync|prune|status)"
	exit 1
	;;
esac
