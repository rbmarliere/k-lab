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

for cmd in git ln make; do
	if ! command -v "$cmd" >/dev/null 2>&1; then
		die "missing required command: $cmd"
	fi
done

mkdir -p -- "$TOOLS_DIR"
link_ktest
"$THIS_DIR"/bin/setup/build-vng
cat <<EOF

Setup complete.

Load the kt shell wrapper and completion with:
  source "$THIS_DIR/k-lab.sh"

Add that line to your shell rc file if you want it by default.

If you want foreign-arch ROOT support in virtme-ng, build the matching static
busybox binary explicitly, for example:
  $THIS_DIR/bin/setup/build-busybox arm64

Run '$THIS_DIR/bin/setup/build-busybox --help' for details.
EOF
