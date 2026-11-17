#!/usr/bin/env bash

_KLAB_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")

kt() {
	"$_KLAB_DIR/bin/kt" "$@"
}

_kt_completion() {
	local cur=${COMP_WORDS[COMP_CWORD]}
	local file
	COMPREPLY=()
	while IFS= read -r file; do
		[[ ! -d $_KLAB_DIR/tests/$file ]] || file+=/
		COMPREPLY+=("$file")
	done < <(cd "$_KLAB_DIR/tests" && compgen -f -- "$cur")
	if [[ ${#COMPREPLY[@]} == 1 && ${COMPREPLY[0]} == */ ]]; then
		compopt -o nospace
	fi
}

complete -o filenames -F _kt_completion kt
