#!/bin/bash -eu

THIS_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")

die() {
	echo "ERROR: $*" >&2
	exit 1
}

# shellcheck disable=SC1091
if ! source "$THIS_DIR/env.sh"; then
	exit 1
fi

bootstrap_vng() {
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
	make -C "$VNG_DIR"
}

if ! command -v make >/dev/null 2>&1; then
	die "missing required command: make"
fi

bootstrap_vng
cat <<EOF

Setup complete.

Load the kt shell wrapper and completion with:
  source "$THIS_DIR/kt.completion"

Add that line to your shell rc file if you want it by default.
EOF
