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
	local resolved

	[[ -n ${ROOT_DISK-} ]] || env_error "ROOT_DISK is not set" || return 1

	if ! resolved=$(realpath -- "$ROOT_DISK" 2>/dev/null); then
		env_error "unable to resolve ROOT_DISK: $ROOT_DISK"
		return 1
	fi
	ROOT_DISK=$resolved

	export ROOT_DISK
	return 0
}

resolve_chroot() {
	local resolved

	[[ -n ${CHROOT-} ]] || env_error "CHROOT is not set" || return 1

	if ! resolved=$(realpath -- "$CHROOT" 2>/dev/null); then
		env_error "unable to resolve CHROOT: $CHROOT"
		return 1
	fi
	CHROOT=$resolved
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
# chroot into, or write to the same path. See chroot_ns_paths below for the
# namespace holder this is actually mounted through.
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

# Paths for the per-TMP_DIR "namespace holder" (see ensure_chroot_ns below)
# that bin/chroot/* joins instead of using real root.
#   CHROOT_NS_PIDFILE = pid of the holder process to nsenter into
#   CHROOT_NS_IDFILE  = holder's user-namespace id, recorded at spawn time
#                       so a reuse check can tell a live holder from a dead
#                       one whose pid got recycled (kill -0 alone can't)
#   CHROOT_NS_READY   = written last, once pidfile+idfile are consistent
#   CHROOT_NS_LOG     = holder's stdout/stderr, surfaced on failure
chroot_ns_paths() {
	local resolved_tmp_dir

	[[ -n ${TMP_DIR-} ]] || env_error "TMP_DIR is not set (required to isolate CHROOT per run)" || return 1

	resolved_tmp_dir=$(realpath -m -- "$TMP_DIR") || {
		env_error "unable to resolve TMP_DIR: $TMP_DIR"
		return 1
	}

	CHROOT_NS_PIDFILE=$resolved_tmp_dir/chroot/ns.pid
	CHROOT_NS_IDFILE=$resolved_tmp_dir/chroot/ns.id
	CHROOT_NS_READY=$resolved_tmp_dir/chroot/ns.ready
	CHROOT_NS_LOG=$resolved_tmp_dir/chroot/ns.log

	export CHROOT_NS_PIDFILE CHROOT_NS_IDFILE CHROOT_NS_READY CHROOT_NS_LOG
	return 0
}

# Read-only check: is the per-TMP_DIR namespace holder running, and
# genuinely the one we spawned? Never spawns one. A bare `kill -0 $pid` is
# not enough since the pid could have been recycled, so this also compares
# the target's user-namespace id against the one recorded at spawn time.
#
# Every mount bin/chroot/* makes lives inside the holder's private mount
# namespace, so "no holder" == "nothing mounted" -- bin/chroot/umount and
# umount-overlay use this to skip entirely instead of spawning one first.
chroot_ns_alive() {
	local pid ns_id

	[[ -n ${CHROOT_NS_PIDFILE-} && -f $CHROOT_NS_PIDFILE && -f ${CHROOT_NS_READY-} ]] || return 1

	pid=$(<"$CHROOT_NS_PIDFILE")
	[[ $pid =~ ^[0-9]+$ ]] || return 1
	kill -0 -- "$pid" 2>/dev/null || return 1

	ns_id=$(readlink -- "/proc/$pid/ns/user" 2>/dev/null) || return 1
	[[ -n $ns_id && -f ${CHROOT_NS_IDFILE-} ]] || return 1
	[[ $ns_id == "$(<"$CHROOT_NS_IDFILE")" ]]
}

# Ensure a per-TMP_DIR namespace holder is running, spawning one if not.
# Idempotent: returns immediately if chroot_ns_alive already says yes.
#
# The holder is a single, long-lived background process:
#   setsid unshare --user --pid --mount --map-root-user --fork -- \
#     bash -c 'while :; do wait -n 2>/dev/null; sleep 0.1; done'
# `--map-root-user` maps the invoking uid/gid to ns-uid/gid 0 (never real
# root). `--mount` gives it a private mount namespace, so every mount
# bin/chroot/mount-overlay and bin/chroot/mount add later is invisible
# outside it and torn down atomically the instant the holder dies (see
# kill_chroot_ns), no separate unmount step needed. `--pid` (with `--fork`,
# required for CLONE_NEWPID to take effect) gives it a private PID
# namespace, needed for `mount -t proc` inside it to work at all.
#
# The holder is pid 1 of that PID namespace, so it must reap anything
# reparented to it: chroot_nsenter forks a fresh member of the namespace
# per call, and an interrupted build's orphaned descendants get reparented
# to the holder. A bare `sleep infinity` never reaps (confirmed: leaves
# permanent zombies); the `wait -n` loop does. This doesn't change how the
# holder handles signals (see kill_chroot_ns): SIGTERM is still ignored,
# exactly like real init.
#
# Every separate, later bin/chroot/* invocation joins this one holder via
# chroot_nsenter instead of creating its own -- a plain `unshare` per
# invocation would be a disconnected namespace that loses all mount state
# once that invocation exits.
#
# The pid to record is not the holder's own `$$`: `unshare --pid --fork`
# does not itself join the new pid namespace (CLONE_NEWPID only takes
# effect for the next forked child), so it's the forked child that becomes
# pid 1 there, and that child's own getpid() is self-referential ("1") and
# useless from outside. Instead this resolves it externally: capture the
# outer `unshare` launcher's pid via `$!`, then `pgrep -P` for its child.
ensure_chroot_ns() {
	local launcher pid ns_id i
	# Bounded, roughly-doubling backoff; spawning the holder is normally
	# near-instant, this just avoids blocking indefinitely if something
	# is badly wrong. Fixed table (not computed) to dodge locale-dependent
	# float formatting breaking `sleep`.
	local -a backoff=(0.05 0.1 0.2 0.4 0.8 1 1 1 1 1)

	chroot_ns_alive && return 0
	rm -f -- "$CHROOT_NS_PIDFILE" "$CHROOT_NS_IDFILE" "$CHROOT_NS_READY"

	mkdir -p -- "$(dirname -- "$CHROOT_NS_PIDFILE")"
	: >"$CHROOT_NS_LOG"

	setsid unshare --user --pid --mount --map-root-user --fork -- \
		bash -c 'while :; do wait -n 2>/dev/null; sleep 0.1; done' \
		</dev/null &>"$CHROOT_NS_LOG" &
	launcher=$!
	disown

	pid=
	for i in "${!backoff[@]}"; do
		pid=$(pgrep -P "$launcher" 2>/dev/null || true)
		[[ $pid =~ ^[0-9]+$ ]] && break
		pid=
		sleep "${backoff[$i]}"
	done

	if [[ -z $pid ]]; then
		env_error "namespace holder failed to start (TMP_DIR=$TMP_DIR)"
		cat -- "$CHROOT_NS_LOG" >&2 2>/dev/null || true
		return 1
	fi

	ns_id=$(readlink -- "/proc/$pid/ns/user" 2>/dev/null) || {
		env_error "namespace holder exited immediately (TMP_DIR=$TMP_DIR)"
		cat -- "$CHROOT_NS_LOG" >&2 2>/dev/null || true
		return 1
	}

	echo "$ns_id" >"$CHROOT_NS_IDFILE"
	echo "$pid" >"$CHROOT_NS_PIDFILE"
	touch "$CHROOT_NS_READY"
	return 0
}

# Direct replacement for every former `"$BIN"/run --as-root -- ...` call in
# bin/chroot/*: joins "$@" to the per-TMP_DIR namespace holder's
# user+mount+pid namespaces (ensure_chroot_ns must already have been called
# in this process) instead of spawning a new, disconnected one.
#
# --preserve-credentials is required: without it, nsenter also tries
# setgroups() on the target's supplementary groups, which fails under the
# single-range --map-root-user mapping the holder uses. Not needed anyway:
# joining the namespace with our own already-mapped credential is enough
# to be seen as ns-uid/gid 0 there.
#
# Mount-table idempotency checks (grep .../proc/mounts) must also go
# through this: /proc/mounts reflects the reading process's own mount
# namespace, so a plain, non-nsentered read would miss mounts that only
# exist inside the holder's private one.
chroot_nsenter() {
	[[ -n ${CHROOT_NS_PIDFILE-} && -f $CHROOT_NS_PIDFILE ]] || env_error "namespace holder is not running (call ensure_chroot_ns first)" || return 1
	nsenter --target "$(<"$CHROOT_NS_PIDFILE")" --user --mount --pid --preserve-credentials -- "$@"
}

# Tear down the per-TMP_DIR namespace holder: killing it atomically tears
# down everything mounted inside it (overlay, proc, dev, sys, binds), with
# no separate unmount step needed or able to race it.
#
# Must be SIGKILL, not a plain `kill`/SIGTERM: as pid 1 of its own PID
# namespace, the holder gets init-like signal semantics and silently
# ignores anything without a handler; only SIGKILL/SIGSTOP get through.
kill_chroot_ns() {
	local pid i ret=0

	[[ -n ${CHROOT_NS_PIDFILE-} && -f $CHROOT_NS_PIDFILE ]] || return 0
	pid=$(<"$CHROOT_NS_PIDFILE")

	if [[ $pid =~ ^[0-9]+$ ]]; then
		kill -9 -- "$pid" 2>/dev/null || true
		for ((i = 0; i < 50; i++)); do
			kill -0 -- "$pid" 2>/dev/null || break
			sleep 0.1
		done
		kill -0 -- "$pid" 2>/dev/null && ret=1
	fi

	rm -f -- "$CHROOT_NS_PIDFILE" "$CHROOT_NS_IDFILE" "$CHROOT_NS_READY"
	return $ret
}
