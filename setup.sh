#!/usr/bin/env bash
set -e

dir=$(dirname -- "$(realpath -- "$0")")
if [[ ! -L $dir/tools/ktest ]]; then
	mkdir -p "$dir/tools/ktest"
	url=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/tools/testing/ktest
	for file in ktest.pl config-bisect.pl; do
		curl -fL "$url/$file" -o "$dir/tools/ktest/$file.tmp"
		chmod +x "$dir/tools/ktest/$file.tmp"
		mv -- "$dir/tools/ktest/$file.tmp" "$dir/tools/ktest/$file"
	done
fi
[[ -e $dir/tools/virtme-ng ]] ||
	git clone https://github.com/arighi/virtme-ng "$dir/tools/virtme-ng"
[[ -e $dir/tools/busybox-static-builder ]] ||
	git clone https://github.com/rbmarliere/busybox-static-builder "$dir/tools/busybox-static-builder"
printf 'Build a static busybox, then source %s/k-lab.sh\n' "$dir"
