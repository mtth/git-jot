#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
shopt -s nullglob

usage() { # [CODE]
	local prog="${0##*/}"
	cat <<-EOF
		Emulate branch-local notes

		Synopsis:
		  $prog [-Eb BRANCH] [-n NAME]
		  $prog -D [-ab BRANCH] [-n NAME]
		  $prog -I [-ab BRANCH] [-l BRANCH | -fr REMOTE]
		  $prog -L [-b BRANCH]
		  $prog -P
		  $prog -V [-tb BRANCH] [-n NAME]
		  $prog -X [-afb BRANCH] [-r REMOTE]
		  $prog -h

		Operations:
		  -D  Delete branch jotting.
		  -E  Edit branch jotting. This is the default command.
		  -I  Import jottings from another branch, defaulting to upstream.
		  -L  List branches or jotting names.
		  -P  Prune jottings matching deleted branches.
		  -X  Export branch jottings.
		  -V  View branch jotting.
		  -h  Show help and exit.

		Options:
		  -a         Do not fail if no jotting is present.
		  -b BRANCH  Branch name. Defaults to the current one.
		  -f         Allow non-fast-forward updates.
		  -l BRANCH  Local branch to copy jottings from.
		  -n NAME    Jotting name. Defaults to default.
		  -q         Be more quiet.
		  -r REMOTE  Remote name.
		  -t         Show notes tree ref instead of contents.
	EOF
	exit "${1:-2}"
}

default_name=default
notes_refprefix=refs/notes/jottings/v1
blobs_refprefix=refs/jottings/v1/blobs
remotenotes_refprefix=refs/jottings/v1/remotes

legacy_notes_refprefix=refs/notes/jottings
legacy_blobs_refprefix=refs/jottings/blobs
legacy_jottings_refprefix=refs/jottings

fail() { # MSG
	printf 'Error: %s\n' "$1" >&2 && exit 1
}

tell() { # ...
	# shellcheck disable=SC2059
	(( OPT_quiet )) || printf "$@"
}

_default_remote() { # KEY
	# https://stackoverflow.com/a/78260478
	local key="$1" remote
	remote="$(git for-each-ref --format="%($key:remotename)" "$OPT_branch")"
	printf '%s' "${remote:-origin}"
}

_check_name() { # NAME
	local name="$1"
	[[ -n $name ]] || return 0
	[[ $name != */* ]] || fail 'jotting name cannot contain /'
	git check-ref-format "$blobs_refprefix/check/$name" ||
		fail "invalid jotting name: $name"
}

_git_notes() { # BRANCH ...
	local branch="$1"
	shift
	git notes --ref "$notes_refprefix/$branch" "$@"
}

_blob_ref() { # BRANCH NAME
	printf '%s/%s/%s' "$blobs_refprefix" "$1" "$2"
}

_remote_notes_ref() { # REMOTE BRANCH
	printf '%s/%s/notes/%s' "$remotenotes_refprefix" "$1" "$2"
}

_find_blob() { # [BRANCH] [NAME]
	local branch="${1:-$OPT_branch}" name="${2:-$OPT_name}" sha
	sha="$(git rev-parse --verify --quiet "$(_blob_ref "$branch" "$name")^{blob}")"
	[[ -n $sha ]] && printf '%s' "$sha"
}

_create_blob() { # [BRANCH] [NAME]
	local branch="${1:-$OPT_branch}" name="${2:-$OPT_name}" sha
	sha="$(\
		printf 'Branch: %s\nName: %s' "$branch" "$name" |
			git hash-object -w --stdin
	)"
	git update-ref "$(_blob_ref "$branch" "$name")" "$sha"
	printf '%s' "$sha"
}

_delete_blob() { # SHA [BRANCH] [NAME]
	local sha="$1" branch="${2:-$OPT_branch}" name="${3:-$OPT_name}"
	git update-ref -d "$(_blob_ref "$branch" "$name")" "$sha"
}

_list_blob_refs() { # [BRANCH] [NAME]
	local branch="${1:-}" name="${2:-}"
	if [[ -n $branch && -n $name ]]; then
		git for-each-ref --format='%(refname)' "$(_blob_ref "$branch" "$name")"
	elif [[ -n $branch ]]; then
		git for-each-ref --format='%(refname)' "$blobs_refprefix/$branch/*"
	else
		git for-each-ref --format='%(refname)' "$blobs_refprefix"
	fi
}

_list_names() { # BRANCH
	local branch="$1" ref path
	_list_blob_refs "$branch" |
		while read -r ref; do
			path="${ref#"$blobs_refprefix/$branch/"}"
			[[ $path != */* ]] && printf '%s\n' "$path"
		done
}

_legacy_migrate_notes() {
	local branch ref obj script
	# shellcheck disable=SC2162
	git for-each-ref --shell \
			--format='ref=%(refname); obj=%(objectname);' \
			"$legacy_notes_refprefix" |
		while read script; do
			eval "$script"
			branch="${ref#"$legacy_notes_refprefix/"}"
			[[ $branch != v1 && $branch != v1/* ]] || continue
			if git rev-parse --verify --quiet "$notes_refprefix/$branch" >/dev/null; then
				_git_notes "$branch" merge -s union "$ref" >/dev/null
			else
				git update-ref "$notes_refprefix/$branch" "$obj"
			fi
			git update-ref -d "$ref" "$obj"
		done
}

_legacy_migrate_blobs() { # PREFIX
	local prefix="$1" branch ref obj script
	# shellcheck disable=SC2162
	git for-each-ref --shell \
			--format='ref=%(refname); obj=%(objectname);' \
			"$prefix" |
		while read script; do
			eval "$script"
			branch="${ref#"$prefix/"}"
			[[ -n $branch ]] || continue
			git update-ref "$(_blob_ref "$branch" "$default_name")" "$obj"
			git update-ref -d "$ref" "$obj"
		done
}

_legacy_migrate_flat_blobs() {
	local branch ref obj script
	# shellcheck disable=SC2162
	git for-each-ref --shell \
			--format='ref=%(refname); obj=%(objectname);' \
			"$legacy_jottings_refprefix" |
		while read script; do
			eval "$script"
			branch="${ref#"$legacy_jottings_refprefix/"}"
			case "$branch" in
				''|blobs|blobs/*|remotes|remotes/*|v1|v1/*) continue ;;
			esac
			git update-ref "$(_blob_ref "$branch" "$default_name")" "$obj"
			git update-ref -d "$ref" "$obj"
		done
}

_legacy_migrate_remote_notes() {
	local path remote branch ref obj script
	# shellcheck disable=SC2162
	git for-each-ref --shell \
			--format='ref=%(refname); obj=%(objectname);' \
			"$legacy_jottings_refprefix/remotes" |
		while read script; do
			eval "$script"
			path="${ref#"$legacy_jottings_refprefix/remotes/"}"
			remote="${path%%/*}"
			branch="${path#*/}"
			[[ -n $remote && -n $branch && $branch != "$path" ]] || continue
			git update-ref "$(_remote_notes_ref "$remote" "$branch")" "$obj"
			git update-ref -d "$ref" "$obj"
		done
}

_migrate_refs() {
	_legacy_migrate_notes
	_legacy_migrate_blobs "$legacy_blobs_refprefix"
	_legacy_migrate_remote_notes
	_legacy_migrate_flat_blobs
}

delete_note() { # /
	local sha
	if ! sha="$(_find_blob)"; then
		if (( ! OPT_allow_empty )); then
			fail 'no jottings to delete'
		fi
		tell 'No %s/%s jottings to delete.\n' "$OPT_branch" "$OPT_name"
		return
	fi
	_git_notes "$OPT_branch" remove "$sha" 2>/dev/null || true
	_delete_blob "$sha"
	tell 'Deleted %s/%s jottings.\n' "$OPT_branch" "$OPT_name"
}

edit_note() { # /
	local has_note=1 sha
	if ! sha="$(_find_blob)"; then
		has_note=0
		sha="$(_create_blob)"
	fi

	_git_notes "$OPT_branch" edit --allow-empty "$sha"

	# TODO: Find a more efficient way to detect the case when the note is empty.
	if [[ -z $(_git_notes "$OPT_branch" show "$sha") ]]; then
		_delete_blob "$sha"
		if (( has_note )); then
			tell 'Deleted %s/%s jottings.\n' "$OPT_branch" "$OPT_name"
		else
			tell 'Skipped empty jottings creation.\n'
		fi
	else
		if (( has_note )); then
			tell 'Updated %s/%s jottings.\n' "$OPT_branch" "$OPT_name"
		else
			tell 'Created %s/%s jottings.\n' "$OPT_branch" "$OPT_name"
		fi
	fi
}

list_notes() { # /
	local ref path branch
	if (( OPT_branch_set )); then
		_list_names "$OPT_branch"
		return
	fi
	{
		printf 'BRANCH\tNAME\n'
		_list_blob_refs |
			while read -r ref; do
				path="${ref#"$blobs_refprefix/"}"
				branch="${path%/*}"
				printf '%s\t%s\n' "$branch" "${path##*/}"
			done
	} | column -t -s $'\t'
}

_import_one_local_note() { # FROMBRANCH NAME
	local frombranch="$1" name="$2" fromsha sha
	fromsha="$(_find_blob "$frombranch" "$name")"
	if ! sha="$(_find_blob "$OPT_branch" "$name")"; then
		sha="$(_create_blob "$OPT_branch" "$name")"
	fi
	_git_notes "$frombranch" show "$fromsha" |
		_git_notes "$OPT_branch" add -f -F - "$sha"
}

import_local_note() { # /
	local name names=()
	while read -r name; do
		names+=("$name")
	done < <(_list_names "$OPT_frombranch")
	if (( ${#names[@]} == 0 )); then
		if (( ! OPT_allow_empty )); then
			fail "no jottings to import from $OPT_frombranch"
		fi
		tell 'No jottings to import from %s.\n' "$OPT_frombranch"
		return
	fi
	tell 'Importing %s jottings from branch %s...\n' "$OPT_branch" "$OPT_frombranch"
	for name in "${names[@]}"; do
		_import_one_local_note "$OPT_frombranch" "$name"
	done
}

_remote_refs() { # REMOTE BRANCH
	local remote="$1" branch="$2" notes_ref blob_ref
	notes_ref="$notes_refprefix/$branch"
	blob_ref="$blobs_refprefix/$branch/*"
	git ls-remote --refs "$remote" "$notes_ref" "$blob_ref" |
		awk '{ print $2 }'
}

import_remote_note() { # /
	[[ -z ${GIT_JOT_IMPORTING:-} ]] || return 0

	local has_blob_ref=0 refs=() ref refspecs=()
	tell 'Importing %s jottings from remote %s...\n' "$OPT_branch" "$OPT_remote"

	while read -r ref; do
		refs+=("$ref")
	done < <(_remote_refs "$OPT_remote" "$OPT_branch")
	if (( ${#refs[@]} == 0 )); then
		if (( ! OPT_allow_empty )); then
			fail 'no remote jottings to import'
		fi
		tell 'No jottings imported.\n'
		return
	fi

	for ref in "${refs[@]}"; do
		if [[ $ref == "$notes_refprefix/$OPT_branch" ]]; then
			refspecs+=("$ref:$(_remote_notes_ref "$OPT_remote" "$OPT_branch")")
		else
			has_blob_ref=1
			refspecs+=("$ref:$ref")
		fi
	done
	if (( ! has_blob_ref )); then
		if (( ! OPT_allow_empty )); then
			fail 'no remote jottings to import'
		fi
		tell 'No jottings imported.\n'
		return
	fi

	local opts=()
	(( ! OPT_force )) || opts+=(-f)
	GIT_JOT_IMPORTING=1 git fetch "${opts[@]}" "$OPT_remote" "${refspecs[@]}"

	if git rev-parse --verify --quiet "$(_remote_notes_ref "$OPT_remote" "$OPT_branch")" >/dev/null; then
		_git_notes "$OPT_branch" merge -s union "$(_remote_notes_ref "$OPT_remote" "$OPT_branch")"
	fi
}

export_note() { # /
	[[ -z ${GIT_JOT_EXPORTING:-} ]] || return 0

	local refs=() refspecs=() ref
	while read -r ref; do
		refs+=("$ref")
	done < <(_list_blob_refs "$OPT_branch")
	if (( ${#refs[@]} == 0 )); then
		if (( ! OPT_allow_empty )); then
			fail 'no jottings to export'
		fi
		tell 'No %s jottings, skipping export.\n' "$OPT_branch"
		return
	fi
	tell 'Exporting %s jottings to remote %s...\n' "$OPT_branch" "$OPT_remote"

	if git rev-parse --verify --quiet "$notes_refprefix/$OPT_branch" >/dev/null; then
		refspecs=("$notes_refprefix/$OPT_branch:$notes_refprefix/$OPT_branch")
	fi
	for ref in "${refs[@]}"; do
		refspecs+=("$ref:$ref")
	done

	local opts=()
	(( ! OPT_force )) || opts+=(-f)
	GIT_JOT_EXPORTING=1 git push "${opts[@]}" "$OPT_remote" "${refspecs[@]}"
}

prune_notes() { # /
	tell 'Pruning jottings...\n'
	local ref path branch name sha obj
	_list_blob_refs |
		while read -r ref; do
			path="${ref#"$blobs_refprefix/"}"
			branch="${path%/*}"
			name="${path##*/}"
			if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
				sha="$(git rev-parse --verify "$ref^{blob}")"
				git update-ref -d "$ref" "$sha"
				_git_notes "$branch" remove "$sha" 2>/dev/null || true
				tell 'Pruned %s/%s jottings.\n' "$branch" "$name"
			fi
		done
	git for-each-ref --format='%(refname)' "$notes_refprefix" |
		while read -r ref; do
			branch="${ref#"$notes_refprefix/"}"
			if ! git rev-parse --verify --quiet "$branch" >/dev/null; then
				obj="$(git rev-parse --verify "$ref")"
				git update-ref -d "$ref" "$obj"
			fi
		done
}

view_note() { # /
	local sha
	if ! sha="$(_find_blob)"; then
		fail 'no jottings to show'
	fi
	if (( OPT_show_tree )); then
		printf '%s\n' "$notes_refprefix/$OPT_branch"
	else
		_git_notes "$OPT_branch" show "$sha"
	fi
}

main() { # ...
	local cmd=EDIT OPT_allow_empty=0 OPT_branch='' OPT_branch_set=0 \
			OPT_force=0 OPT_frombranch='' OPT_name="$default_name" \
			OPT_quiet=0 OPT_remote='' OPT_show_tree=0 opt
	while getopts :DEILPVXab:fhl:n:qr:t opt "$@"; do
		case "$opt" in
			D) cmd=DELETE ;;
			E) cmd=EDIT ;;
			I) cmd=IMPORT ;;
			L) cmd=LIST ;;
			P) cmd=PRUNE ;;
			V) cmd=VIEW ;;
			X) cmd=EXPORT ;;
			a) OPT_allow_empty=1 ;;
			b) OPT_branch="$OPTARG"; OPT_branch_set=1 ;;
			f) OPT_force=1 ;;
			h) usage 0 ;;
			l) OPT_frombranch="$OPTARG" ;;
			n) OPT_name="$OPTARG" ;;
			q) OPT_quiet=1 ;;
			r) OPT_remote="$OPTARG" ;;
			t) OPT_show_tree=1 ;;
			*) fail "unknown option: $OPTARG" ;;
		esac
	done
	shift $(( OPTIND-1 ))
	(( $# == 0 )) || fail 'trailing arguments'

	_check_name "$OPT_name"
	if [[ -z $OPT_branch && $cmd != LIST ]]; then
		OPT_branch="$(git rev-parse --abbrev-ref HEAD)" # Current branch
	elif [[ -z $OPT_branch && $cmd == LIST && $OPT_branch_set -eq 1 ]]; then
		OPT_branch="$(git rev-parse --abbrev-ref HEAD)"
	fi

	_migrate_refs
	case "$cmd" in
		DELETE) delete_note ;;
		EDIT) edit_note ;;
		EXPORT)
			OPT_remote="${OPT_remote:-$(_default_remote push)}"
			export_note
			;;
		IMPORT)
			if [[ -z $OPT_branch ]]; then
				OPT_branch="$(git rev-parse --abbrev-ref HEAD)"
			fi
			if [[ -z $OPT_frombranch && -z $OPT_remote ]]; then
				OPT_remote="${OPT_remote:-$(_default_remote upstream)}"
			elif [[ -n $OPT_frombranch && -n $OPT_remote ]]; then
				fail 'only one of -l and -r can be set'
			fi
			if [[ -n $OPT_remote ]]; then
				import_remote_note
			else
				import_local_note
			fi
		;;
		LIST) list_notes ;;
		PRUNE) prune_notes ;;
		VIEW) view_note ;;
	esac
}

main "$@"
