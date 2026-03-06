#!/bin/bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	echo "ERROR: source ${BASH_SOURCE[0]} to load the k-lab environment" >&2
	exit 1
fi

this_dir=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
SETUP_CONF=$this_dir/setup.conf
if [[ ! -r $SETUP_CONF ]]; then
	echo "ERROR: unable to read setup config: $SETUP_CONF" >&2
	return 1
fi

read_setup_var() {
	local key=$1

	awk -v key="$key" '
		$0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
		$0 ~ "^[[:space:]]*" key "[[:space:]]*:?=" {
			sub("^[[:space:]]*" key "[[:space:]]*:?=[[:space:]]*", "", $0)
			print
			exit
		}
	' "$SETUP_CONF"
}

LINUX_GIT=$(read_setup_var LINUX_GIT)
THIS_DIR=$(read_setup_var THIS_DIR)

for var in LINUX_GIT THIS_DIR; do
	if [[ -z ${!var-} ]]; then
		echo "ERROR: $var is not set in $SETUP_CONF" >&2
		return 1
	fi
done

if ! configured_dir=$(realpath -- "$THIS_DIR" 2>/dev/null); then
	echo "ERROR: THIS_DIR points to a missing directory: $THIS_DIR" >&2
	return 1
fi
if [[ $configured_dir != "$this_dir" ]]; then
	echo "ERROR: THIS_DIR in $SETUP_CONF is '$configured_dir', but this checkout is '$this_dir'" >&2
	return 1
fi

if [[ ! -d $LINUX_GIT ]]; then
	echo "ERROR: LINUX_GIT points to a missing directory: $LINUX_GIT" >&2
	return 1
fi
if ! git -C "$LINUX_GIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "ERROR: LINUX_GIT is not a git worktree: $LINUX_GIT" >&2
	return 1
fi

KTEST_PL=$LINUX_GIT/tools/testing/ktest/ktest.pl
if [[ ! -f $KTEST_PL ]]; then
	echo "ERROR: missing ktest.pl: $KTEST_PL" >&2
	return 1
fi

VNG_DIR=$THIS_DIR/virtme-ng

export THIS_DIR KTEST_PL VNG_DIR
