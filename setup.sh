#!/usr/bin/env bash
set -e

dir=$(dirname -- "$(realpath -- "$0")")
if [[ ! -L $dir/tools/ktest ]]; then
	url=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/tools/testing/ktest
	for file in \
		ktest.pl config-bisect.pl sample.conf \
		examples/README \
		examples/{crosstests,kvm,snowball,test,vmware}.conf \
		examples/include/{bisect,bootconfig,defaults,min-config,patchcheck,tests}.conf \
		examples/bootconfigs/{boottrace,functiongraph,tracing}.bconf \
		examples/bootconfigs/config-bootconfig \
		examples/bootconfigs/verify-{boottrace,functiongraph,tracing}.sh; do
		dest=$dir/tools/ktest/$file
		mkdir -p -- "$(dirname -- "$dest")"
		curl -fL "$url/$file" -o "$dest.tmp"
		case $file in
			*.pl|*.sh) chmod +x "$dest.tmp" ;;
		esac
		mv -- "$dest.tmp" "$dest"
	done
fi
[[ -e $dir/tools/virtme-ng ]] ||
	git clone https://github.com/arighi/virtme-ng "$dir/tools/virtme-ng"
[[ -e $dir/tools/busybox-static-builder ]] ||
	git clone https://github.com/rbmarliere/busybox-static-builder "$dir/tools/busybox-static-builder"
printf 'Build a static busybox, then source %s/k-lab.sh\n' "$dir"
