#!/usr/bin/env bash
set -e

dir=$(dirname -- "$(realpath -- "$0")")
linux=$(awk '/^[[:space:]]*LINUX_GIT[[:space:]]*:=/ {sub(/^[^:]*:=[[:space:]]*/, ""); print; exit}' "$dir/setup.conf")
mkdir -p "$dir/tools"
ln -sfnT "$linux/tools/testing/ktest" "$dir/tools/ktest"
[[ -e $dir/tools/virtme-ng ]] ||
	git clone https://github.com/arighi/virtme-ng "$dir/tools/virtme-ng"
[[ -e $dir/tools/busybox-static-builder ]] ||
	git clone https://github.com/rbmarliere/busybox-static-builder "$dir/tools/busybox-static-builder"
printf 'Build a static busybox, then source %s/k-lab.sh\n' "$dir"
