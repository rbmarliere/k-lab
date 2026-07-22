#!/bin/bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	echo "ERROR: source ${BASH_SOURCE[0]} to load the k-lab environment" >&2
	exit 1
fi

THIS_DIR=$(realpath -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")/..")
BIN=$THIS_DIR/bin
SETUP_CONF=$THIS_DIR/setup.conf
TOOLS_DIR=$THIS_DIR/tools
KTEST_DIR=$TOOLS_DIR/ktest
VNG_DIR=$TOOLS_DIR/virtme-ng
BUSYBOX_DIR=$TOOLS_DIR/busybox

export THIS_DIR BIN SETUP_CONF TOOLS_DIR KTEST_DIR VNG_DIR BUSYBOX_DIR

# Canonical list of the k-lab runtime env: the variables that must survive the
# ktest.pl -> shell boundary into hooks/ and the rest of bin/. This is the
# single source of truth consumed by bin/write-env (which persists them to
# $TMP_DIR/env.sh for bin/run to re-source). Each name here, except BIN (set
# above), is fed across the boundary by a matching "ENV := ${ENV} K=..." line
# in include/*.conf; keep the two in sync when adding or removing a variable.
KLAB_ENV_KEYS=(
	BIN TOOLS_DIR BUILD_DIR BUILD_OPTIONS ROOT_DISK CHROOT_BUILD CHROOT
	ARCH CROSS_COMPILE BUILD_TARGET VNG_DIR VNG_PORT VNG_MEM TMP_DIR OUTPUT_DIR
	CC HOSTCC HOSTCFLAGS COMPILE_COMMANDS
)
export KLAB_ENV_KEYS

env_error() {
	echo "ERROR: $*" >&2
	return 1
}

read_setup_var() {
	local key=$1

	[[ -r $SETUP_CONF ]] || return 1

	awk -v key="$key" '
		$0 ~ /^[[:space:]]*#/ || $0 ~ /^[[:space:]]*$/ { next }
		$0 ~ "^[[:space:]]*" key "[[:space:]]*:?=" {
			sub("^[[:space:]]*" key "[[:space:]]*:?=[[:space:]]*", "", $0)
			print
			exit
		}
	' "$SETUP_CONF"
}

require_setup_conf() {
	[[ -r $SETUP_CONF ]] || env_error "unable to read setup config: $SETUP_CONF"
}

load_setup_conf() {
	local configured_this_dir configured_dir

	if [[ -n ${_KLAB_SETUP_LOADED-} ]]; then
		return 0
	fi

	require_setup_conf || return 1

	LINUX_GIT=$(read_setup_var LINUX_GIT || true)
	configured_this_dir=$(read_setup_var THIS_DIR || true)

	if [[ -z ${LINUX_GIT-} ]]; then
		env_error "LINUX_GIT is not set in $SETUP_CONF"
		return 1
	fi
	if [[ -z $configured_this_dir ]]; then
		env_error "THIS_DIR is not set in $SETUP_CONF"
		return 1
	fi

	if ! configured_dir=$(realpath -- "$configured_this_dir" 2>/dev/null); then
		env_error "THIS_DIR points to a missing directory: $configured_this_dir"
		return 1
	fi
	if [[ $configured_dir != "$THIS_DIR" ]]; then
		env_error "THIS_DIR in $SETUP_CONF is '$configured_dir', but this checkout is '$THIS_DIR'"
		return 1
	fi

	KTEST_PL=$LINUX_GIT/tools/testing/ktest/ktest.pl

	export LINUX_GIT KTEST_PL
	_KLAB_SETUP_LOADED=1
	return 0
}

require_linux_git() {
	load_setup_conf || return 1

	if [[ ! -d $LINUX_GIT ]]; then
		env_error "LINUX_GIT points to a missing directory: $LINUX_GIT"
		return 1
	fi
	if ! git -C "$LINUX_GIT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		env_error "LINUX_GIT is not a git worktree: $LINUX_GIT"
		return 1
	fi

	return 0
}

require_ktest() {
	require_linux_git || return 1

	if [[ ! -f $KTEST_PL ]]; then
		env_error "missing ktest.pl: $KTEST_PL"
		return 1
	fi

	return 0
}

require_vng() {
	if [[ ! -d $VNG_DIR || ! -x $VNG_DIR/vng ]]; then
		env_error "VNG_DIR is not ready: $VNG_DIR"
		return 1
	fi

	if ! PATH="$VNG_DIR:$VNG_DIR/virtme/guest/bin:$PATH" "$VNG_DIR/vng" --help >/dev/null 2>&1; then
		env_error "virtme-ng is present but cannot start; check its Python dependencies in $VNG_DIR"
		return 1
	fi

	return 0
}

resolve_root_disk() {
	[[ -n ${ROOT_DISK-} ]] || env_error "ROOT_DISK is not set" || return 1

	if ! ROOT_DISK=$(realpath -- "$ROOT_DISK" 2>/dev/null); then
		env_error "unable to resolve ROOT_DISK: $ROOT_DISK"
		return 1
	fi

	export ROOT_DISK
	return 0
}

resolve_chroot() {
	[[ -n ${CHROOT-} ]] || env_error "CHROOT is not set" || return 1

	if ! CHROOT=$(realpath -- "$CHROOT" 2>/dev/null); then
		env_error "unable to resolve CHROOT: $CHROOT"
		return 1
	fi
	if [[ ! -d $CHROOT ]]; then
		env_error "CHROOT is not a directory: $CHROOT"
		return 1
	fi

	export CHROOT
	return 0
}

# Every run gets its own private, writable, copy-on-write view of CHROOT:
#   CHROOT_MERGED = overlay(lowerdir=CHROOT, upperdir=CHROOT_UPPER) -- what
#                   the chrooted build actually reads and writes.
#   CHROOT_UPPER  = per-run writable layer
#   CHROOT_WORK   = overlayfs scratch dir (required, never accessed directly)
# This keeps CHROOT itself read-only and shared, so concurrent runs against
# the same CHROOT (e.g. a shared CHROOT_ARM64 in setup.conf) never mount,
# chroot into, or write to the same path.
chroot_overlay_paths() {
	local resolved_tmp_dir

	[[ -n ${TMP_DIR-} ]] || env_error "TMP_DIR is not set (required to isolate CHROOT per run)" || return 1

	# Canonicalize TMP_DIR (e.g. resolve the /linux/k-lab symlink) so
	# CHROOT_MERGED matches what mount(8) actually records in /proc/mounts.
	resolved_tmp_dir=$(realpath -m -- "$TMP_DIR") || {
		env_error "unable to resolve TMP_DIR: $TMP_DIR"
		return 1
	}

	CHROOT_UPPER=$resolved_tmp_dir/chroot/upper
	CHROOT_WORK=$resolved_tmp_dir/chroot/work
	CHROOT_MERGED=$resolved_tmp_dir/chroot/merged

	export CHROOT_UPPER CHROOT_WORK CHROOT_MERGED
	return 0
}
