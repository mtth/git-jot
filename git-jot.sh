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
		  $prog [-Eb BRANCH]
		  $prog -D [-ab BRANCH]
		  $prog -I [-aeb BRANCH] [-l BRANCH | -fr REMOTE]
		  $prog -L
		  $prog -P
		  $prog -V [-tb BRANCH]
		  $prog -X [-afb BRANCH] [-r REMOTE]
		  $prog -h

		Operations:
		  -D  Delete branch note.
		  -E  Edit branch note. This is the default command.
		  -I  Import note from another branch, defaulting to upstream.
		  -L  List branches with notes.
		  -P  Prune notes matching deleted branches.
		  -X  Export branch notes.
		  -V  View branch note.
		  -h  Show help and exit.

		Options:
		  -a         Do not fail if no note is present.
		  -b BRANCH  Branch name. Defaults to the current one.
		  -e         Edit the imported note.
		  -l BRANCH  Local branch to copy the note from.
		  -r REMOTE  Remote name.
		  -t         Show notes tree ref instead of contents.
	EOF
	exit "${1:-2}"
}

notes_refprefix=refs/notes/jottings
remotenotes_refprefix=refs/jottings/remotes
blobs_refprefix=refs/jottings/blobs
blobs_remote_refprefix=refs/jottings

fail() { # MSG
	printf 'Error: %s\n' "$1" >&2 && exit 1
}

_default_remote() { # KEY
	# https://stackoverflow.com/a/78260478
	local key="$1" remote
	remote="$(git for-each-ref --format="%($key:remotename)" "$_JOTTINGS_BRANCH")"
	printf '%s' "${remote:-origin}"
}

_git_notes() { # BRANCH ...
	local branch="$1"
	shift
	git notes --ref "$notes_refprefix/$branch" "$@"
}

_find_blob() { # [BRANCH]
	local branch="${1:-$_JOTTINGS_BRANCH}" sha
	sha="$(git rev-parse --verify --quiet "$blobs_refprefix/$branch^{blob}")"
	[[ -n $sha ]] && printf '%s' "$sha"
}

_create_blob() { # /
	local sha
	sha="$(\
		printf 'Branch: %s' "$_JOTTINGS_BRANCH" |
			git hash-object -w --stdin
	)"
	git update-ref "$blobs_refprefix/$_JOTTINGS_BRANCH" "$sha"
	printf '%s' "$sha"
}

_delete_blob() { # SHA
		local sha="$1"
		git update-ref -d "$blobs_refprefix/$_JOTTINGS_BRANCH" "$sha"
}

delete_note() { # ALLOW_EMPTY
	local allow_empty="$1" sha
	if ! sha="$(_find_blob)"; then
		if (( ! allow_empty )); then
			fail 'no jottings to delete'
		fi
		printf 'No %s jottings to delete.\n' "$_JOTTINGS_BRANCH"
		return
	fi
	_git_notes "$_JOTTINGS_BRANCH" remove "$sha" 2>/dev/null
	_delete_blob "$sha"
	printf 'Deleted %s jottings.\n' "$_JOTTINGS_BRANCH"
}

edit_note() { # /
	local has_note=1 sha
	if ! sha="$(_find_blob)"; then
		has_note=0
		sha="$(_create_blob)"
	fi

	_git_notes "$_JOTTINGS_BRANCH" edit --allow-empty "$sha"

	# TODO: Find a more efficient way to detect the case when the note is empty.
	if [[ -z $(_git_notes "$_JOTTINGS_BRANCH" show "$sha") ]]; then
		_delete_blob "$sha"
		if (( has_note )); then
			printf 'Deleted %s jottings.\n' "$_JOTTINGS_BRANCH"
		else
			printf 'Skipped empty jottings creation.\n'
		fi
	else
		if (( has_note )); then
			printf 'Updated %s jottings.\n' "$_JOTTINGS_BRANCH"
		else
			printf 'Created %s jottings.\n' "$_JOTTINGS_BRANCH"
		fi
	fi
}

list_notes() { # /
	git for-each-ref --format='%(refname:lstrip=3)' "$blobs_refprefix"
}

import_local_note() { # FROMBRANCH ALLOW_EMPTY EDIT
	local frombranch="$1" allow_empty="$2" edit="$3" fromsha sha
	if ! fromsha="$(_find_blob "$frombranch")"; then
		if (( ! allow_empty )); then
			fail "no jottings to import from $frombranch"
		fi
		printf 'No jottings to import from %s.\n' "$frombranch"
		return
	fi
	printf 'Importing %s jottings from branch %s...\n' \
		"$_JOTTINGS_BRANCH" "$frombranch"

	local sha
	if ! sha="$(_find_blob)"; then
		sha="$(_create_blob)"
	fi

	_git_notes "$frombranch" show "$fromsha" |
		_git_notes "$_JOTTINGS_BRANCH" add -F - "$sha"

	(( ! edit )) || _git_notes "$_JOTTINGS_BRANCH" edit "$sha"
}

import_remote_note() { # REMOTE ALLOW_EMPTY EDIT FORCE
	[[ -z ${GIT_JOT_IMPORTING:-} ]] || return 0

	local remote="$1" allow_empty="$2" edit="$3" sha
	printf 'Importing %s jottings from remote %s...\n' \
		"$_JOTTINGS_BRANCH" "$remote"

	local opts=()
	(( ! force )) || opts+=(-f)
	GIT_JOT_IMPORTING=1 git fetch "${opts[@]}" "$remote" \
			"$notes_refprefix/$_JOTTINGS_BRANCH:$remotenotes_refprefix/$remote/$_JOTTINGS_BRANCH" \
			"$blobs_remote_refprefix/$_JOTTINGS_BRANCH:$blobs_refprefix/$_JOTTINGS_BRANCH"

	_git_notes "$_JOTTINGS_BRANCH" merge -s union \
			"$remotenotes_refprefix/$remote/$_JOTTINGS_BRANCH"

	if ! sha="$(_find_blob)"; then
		if (( ! allow_empty )); then
			fail 'no remote jottings to import'
		fi
		printf 'No jottings imported.\n'
		return
	fi

	(( ! edit )) || _git_notes "$_JOTTINGS_BRANCH" edit "$sha"
}

export_note() { # REMOTE ALLOW_EMPTY FORCE
	[[ -z ${GIT_JOT_EXPORTING:-} ]] || return 0

	local remote="$1" allow_empty="$2" force="$3"
	if ! _find_blob >/dev/null; then
		if (( ! allow_empty )); then
			fail 'no jottings to export'
		fi
		printf 'No %s jottings, skipping export.\n' "$_JOTTINGS_BRANCH"
		return
	fi
	printf 'Exporting %s jottings to remote %s...\n' "$_JOTTINGS_BRANCH" "$remote"

	local opts=()
	(( ! force )) || opts+=(-f)
	GIT_JOT_EXPORTING=1 git push "${opts[@]}" "$remote" \
			"$notes_refprefix/$_JOTTINGS_BRANCH:$notes_refprefix/$_JOTTINGS_BRANCH" \
			"$blobs_refprefix/$_JOTTINGS_BRANCH:$blobs_remote_refprefix/$_JOTTINGS_BRANCH"
}

prune_notes() { # /
	printf 'Pruning jottings...\n'
	local script name ref
	# shellcheck disable=SC2162
	git for-each-ref --shell \
			--format='name=%(refname:lstrip=3); ref=%(refname);' \
			"$blobs_refprefix" |
		while read script; do
			eval "$script"
			if ! git rev-parse --verify --quiet "$name"; then
				git update-ref -d "$ref"
				_git_notes "$name" prune -v
				printf 'Pruned %s jottings.\n' "$name"
			fi
		done
}

view_note() { # SHOW_TREE /
	local show_tree="$1" sha
	if ! sha="$(_find_blob)"; then
		fail 'no jottings to show'
	fi
	if (( show_tree )); then
		printf '%s\n' "$notes_refprefix/$_JOTTINGS_BRANCH"
	else
		_git_notes "$_JOTTINGS_BRANCH" show "$sha"
	fi
}

_migrate_refs() {
	local name ref obj
	# shellcheck disable=SC2162
	git for-each-ref --shell \
			--format='name=%(refname:lstrip=2); ref=%(refname); obj=%(objectname);' \
			"$blobs_remote_refprefix/*" |
		while read script; do
			eval "$script"
			git update-ref "$blobs_refprefix/$name" "$obj"
			git update-ref -d "$blobs_remote_refprefix/$name" "$obj"
		done
}

main() { # ...
	local _JOTTINGS_BRANCH='' \
			allow_empty=0 cmd=edit edit=0 force=0 frombranch='' remote='' \
			show_tree=0 opt
	while getopts :DEILPVXab:efhl:r:t opt "$@"; do
		case "$opt" in
			D) cmd=delete ;;
			E) cmd=edit ;;
			I) cmd=import ;;
			L) cmd=list ;;
			P) cmd=prune ;;
			V) cmd=view ;;
			X) cmd='export' ;;
			a) allow_empty=1 ;;
			b) _JOTTINGS_BRANCH="$OPTARG" ;;
			e) edit=1 ;;
			f) force=1 ;;
			h) usage 0 ;;
			l) frombranch="$OPTARG" ;;
			r) remote="$OPTARG" ;;
			t) show_tree=1 ;;
			*) fail "unknown option: $OPTARG" ;;
		esac
	done
	shift $(( OPTIND-1 ))
	(( $# == 0 )) || fail 'trailing arguments'

	if [[ -z $_JOTTINGS_BRANCH ]]; then
		_JOTTINGS_BRANCH="$(git rev-parse --abbrev-ref HEAD)" # Current branch
	fi

	_migrate_refs
	case "$cmd" in
		delete) delete_note "$allow_empty" ;;
		edit) edit_note ;;
		export)
			remote="${remote:-$(_default_remote push)}"
			export_note "$remote" "$allow_empty" "$force"
			;;
		import)
			if [[ -z $frombranch ]] && [[ -z $remote ]]; then
				remote="${remote:-$(_default_remote upstream)}"
			elif [[ -n $frombranch ]] && [[ -n $remote ]]; then
				fail 'only one of -l and -r can be set'
			fi
			if [[ -n $remote ]]; then
				import_remote_note "$remote" "$allow_empty" "$edit" "$force"
			else
				import_local_note "$frombranch" "$allow_empty" "$edit"
			fi
		;;
		list) list_notes ;;
		prune) prune_notes ;;
		view) view_note "$show_tree" ;;
	esac
}

main "$@"
