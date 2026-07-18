#!/bin/bash -eu

THIS_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")

die() {
	echo "ERROR: $*" >&2
	exit 1
}

# shellcheck disable=SC1091
if ! source "$THIS_DIR/bin/env.sh"; then
	exit 1
fi
if ! require_linux_git; then
	exit 1
fi

link_ktest() {
	local target=$LINUX_GIT/tools/testing/ktest

	[[ -d $target ]] || die "missing ktest directory: $target"
	mkdir -p -- "$TOOLS_DIR"

	if [[ -e $KTEST_DIR && ! -L $KTEST_DIR ]]; then
		die "KTEST_DIR exists but is not a symlink: $KTEST_DIR"
	fi

	ln -sfn -- "$target" "$KTEST_DIR"
}

clone_vng() {
	if [[ -e $VNG_DIR && ! -d $VNG_DIR ]]; then
		die "VNG_DIR exists but is not a directory: $VNG_DIR"
	fi
	if [[ ! -d $VNG_DIR ]]; then
		mkdir -p -- "$(dirname -- "$VNG_DIR")"
		git clone --single-branch https://github.com/arighi/virtme-ng "$VNG_DIR"
	fi
	if [[ ! -f $VNG_DIR/Makefile ]]; then
		die "virtme-ng checkout looks incomplete: $VNG_DIR"
	fi
}

for cmd in git ln make; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		die "missing required command: $cmd"
	fi
done

mkdir -p -- "$TOOLS_DIR"
link_ktest
clone_vng
cat <<EOF

Setup complete.

Load the kt shell wrapper and completion with:
  source "$THIS_DIR/k-lab.sh"

Add that line to your shell rc file if you want it by default.

Before using kt or virtme-ng, build the matching static busybox and QEMU
binaries for the arch you want to boot, and the virtiofsd daemon, for example:
  $THIS_DIR/bin/setup/build-busybox x86_64
  $THIS_DIR/bin/setup/build-qemu x86_64
  $THIS_DIR/bin/setup/build-virtiofsd

Run any of them with --help for details.
EOF
