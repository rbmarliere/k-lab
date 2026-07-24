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
# per-run namespace holder that all of this is actually mounted through.
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
# that bin/chroot/* joins instead of using real root. Same $TMP_DIR/chroot/
# directory as chroot_overlay_paths above.
#   CHROOT_NS_PIDFILE = pid of the holder process to nsenter into
#   CHROOT_NS_IDFILE  = the holder's user-namespace id (readlink of
#                       /proc/$pid/ns/user), recorded at spawn time so a
#                       later reuse check can tell a live holder from a
#                       dead one whose pid the kernel has since recycled
#                       for an unrelated process (a bare `kill -0` cannot
#                       tell those apart)
#   CHROOT_NS_READY   = written last, once the pidfile+idfile pair above is
#                       fully and consistently recorded
#   CHROOT_NS_LOG     = the holder's stdout/stderr, surfaced on failure
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

# Read-only check: is the per-TMP_DIR namespace holder currently running,
# and genuinely the one we (or an earlier run against this same TMP_DIR)
# actually spawned? Never spawns one. A bare `kill -0 $pid` is not enough:
# if the holder died and the kernel has since recycled its pid for an
# unrelated process, kill -0 would report "alive" for the wrong process, so
# this also compares the target's user-namespace id against the one
# recorded when it was spawned (see chroot_ns_paths).
#
# Because every mount bin/chroot/* makes lives inside the holder's own
# private mount namespace (see ensure_chroot_ns), "no holder" and "nothing
# mounted" are equivalent -- bin/chroot/umount and bin/chroot/umount-overlay
# use this to skip entirely instead of spawning a holder only to find (or
# make) nothing to unmount.
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
# Idempotent: if chroot_ns_alive already says yes, returns immediately.
#
# The holder is a single, long-lived background process:
#   setsid unshare --user --pid --mount --map-root-user --fork -- \
#     bash -c 'while :; do wait -n 2>/dev/null; sleep 0.1; done'
# `--map-root-user` maps the invoking uid/gid to ns-uid/gid 0 (never real
# root: it is the exact same real, unprivileged host uid the whole time,
# just seen as 0 from inside this namespace). `--mount` gives it a private
# mount namespace, so every overlay/proc/dev/sys/bind mount that
# bin/chroot/mount-overlay and bin/chroot/mount add to it later (nothing is
# mounted by the holder itself) is invisible outside it and -- unlike the
# old real-root design's umount/umount-overlay retry and lazy-unmount
# dance -- torn down atomically, with no races, the instant the process
# holding it open dies (see kill_chroot_ns). `--pid` (plus `--fork`, which
# unshare(1) requires for CLONE_NEWPID to actually take effect on anything
# it execs) gives it a private PID namespace, needed so a later
# `mount -t proc` inside it succeeds at all (mounting procfs for a pidns
# your own userns does not own is EPERM).
#
# The holder is pid 1 of that new PID namespace, which makes it responsible
# for reaping (see pid_namespaces(7)) anything that gets reparented to it --
# and something *will*: chroot_nsenter's nsenter forks a fresh, genuine
# member of this namespace for every single call, so a real build's whole
# process tree (make -> gcc -> cc1, etc.) normally reaps itself as each
# level exits normally, but if that tree is ever interrupted from outside
# (a killed ktest.pl, a Ctrl-C'd kt run, anything that kills some
# chroot_nsenter'd process without it having a chance to wait() for its own
# children first), the orphaned descendants still get reparented to pid 1
# of their namespace like any orphan does -- i.e. to this holder -- and
# then, once they finish, they need pid 1 to actually collect their exit
# status, or they sit forever as zombies. A bare `sleep infinity` here
# would never do that (confirmed empirically: a build interrupted this way
# left dozens of `<defunct>` cc1/make processes permanently parented to the
# holder). `while :; do wait -n 2>/dev/null; sleep 0.1; done` does: bash's
# `wait` reaps any child with a real, current ppid pointing at this shell
# -- including ones adopted this way, not just ones this shell directly
# forked itself -- confirmed empirically the same way. This does not affect
# how the holder itself responds to signals (see kill_chroot_ns): it still
# has no handler for SIGTERM, so the same pid-1 semantics (SIGTERM ignored,
# only SIGKILL/SIGSTOP are not) apply exactly as they would to `sleep
# infinity`.
#
# This is the one long-lived process that every separate, later
# bin/chroot/* invocation joins via chroot_nsenter instead of creating its
# own namespace: a plain `unshare` per invocation would create a new,
# disconnected namespace each time and lose all mount state the instant
# that invocation exits, since mount/run/umount/umount-overlay are
# separate process invocations that (before this) only shared mount state
# because real-root sudo mounts landed in the host's one shared,
# persistent mount namespace.
#
# Recording the right pid to nsenter into later is the subtle part: `id -u`
# inside the holder reports 0, but the *pid* that must be recorded is not
# as simple as reading the holder's own `$$`. `unshare --pid --fork CMD`
# does not itself become a member of the new pid namespace -- per
# unshare(1)/pid_namespaces(7), CLONE_NEWPID only takes effect for the
# *next* forked child, so the outer `unshare` process remains, itself, a
# member of the OLD/outer pid namespace, and it is the separate child it
# forks (because of --fork) that becomes pid 1 of, and a genuine member of
# all three new namespaces (user+mount+pid) at once. That child's own
# `$$`/getpid() is self-referential (always relative to its own innermost
# namespace) and would print "1" -- correct from its own point of view, but
# useless to any separate, later process trying to nsenter into it from
# outside (confirmed empirically while implementing this; see
# plans/03-chroot-build-userns.md). So instead of asking the child to
# report its own pid, this resolves it from the outside: capture the outer
# `unshare` launcher's pid via `$!` right after backgrounding it, then ask
# the process table for *its* child (`pgrep -P`, standard and portable --
# unlike e.g. /proc/PID/task/TID/children, it needs no optional kernel
# config), which is the pid every later chroot_nsenter call must target.
ensure_chroot_ns() {
	local launcher pid ns_id i
	# Bounded, roughly-doubling backoff (mirrors virtme-ng's own
	# VirtioFS._get_virtiofsd_path/start polling idiom), spelled out as a
	# fixed table rather than computed to avoid locale-dependent float
	# formatting (e.g. "," vs "." as the decimal separator) breaking
	# `sleep`. Spawning the holder is normally near-instant; this just
	# avoids blocking indefinitely if something is badly wrong.
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
# bin/chroot/*: run "$@" joined to the per-TMP_DIR namespace holder's
# user+mount+pid namespaces (ensure_chroot_ns must have already been called
# in this same process, so CHROOT_NS_PIDFILE is set) instead of spawning a
# new, disconnected one.
#
# --preserve-credentials is required: without it, nsenter also tries to
# adopt the target's supplementary groups via setgroups(), which fails
# ("setgroups failed: Operation not permitted", confirmed empirically) under
# the single-range --map-root-user mapping the holder uses. Skipping that is
# fine because joining a user namespace with our own, already-mapped real
# credential is already enough to be seen as ns-uid/gid 0 there -- no
# explicit setuid()/setgid() call is needed.
#
# Mount-table idempotency checks (grep ... /proc/mounts) must also be routed
# through this: /proc/mounts always reflects the *reading* process's own
# mount namespace, so a bare, non-nsentered `grep ... /proc/mounts` from an
# ordinary caller would never see mounts that live only inside the holder's
# private mount namespace (this works correctly the other way around
# because `unshare --mount` starts as an independent copy of the parent's
# mount table at unshare time -- including its inherited, perfectly normal
# top-level /proc -- so /proc/mounts read via chroot_nsenter faithfully
# reflects the holder's private mount table, both the inherited entries and
# anything mounted into it since).
chroot_nsenter() {
	[[ -n ${CHROOT_NS_PIDFILE-} && -f $CHROOT_NS_PIDFILE ]] || env_error "namespace holder is not running (call ensure_chroot_ns first)" || return 1
	nsenter --target "$(<"$CHROOT_NS_PIDFILE")" --user --mount --pid --preserve-credentials -- "$@"
}

# Tear down the per-TMP_DIR namespace holder. Unlike the old real-root
# design, where mounts landed in the host's shared, persistent mount
# namespace and had to be individually unmounted (see bin/chroot/umount's
# and bin/chroot/umount-overlay's own retry/lazy-unmount logic), this alone
# is now what completes teardown: killing the process holding the
# namespaces open atomically tears down everything mounted inside it
# (overlay, proc, dev, sys, binds), with no separate unmount step able to
# race it, because nothing outside that namespace could ever see or race
# against those mounts in the first place.
#
# Must be SIGKILL, not a plain `kill`/SIGTERM: the holder is pid 1 of its
# own PID namespace, and Linux gives init-like (pid 1) processes special
# signal semantics -- SIGTERM (or any signal without a registered handler)
# is silently ignored, exactly like real init; only SIGKILL and SIGSTOP are
# never ignorable for such a process (confirmed empirically: a plain `kill`
# left the holder running). Killing it also unblocks the outer `unshare`
# launcher process (which just wait(2)s on this one child and does nothing
# else), so nothing needs to be tracked or separately signaled for it.
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
