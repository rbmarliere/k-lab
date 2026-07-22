# k-lab

`k-lab` is a thin layer on top of `ktest.pl` for local kernel build, boot, and
test loops with `virtme-ng`.

It keeps `ktest.pl` as the control plane, uses `virtme-ng` as the VM backend,
and can also boot an external disk image instead of sharing the host
filesystem.

This repo gives you:

- shared config fragments under `include/`
- ready-to-edit test configs under `tests/`
- runtime helpers under `bin/` and `hooks/`
- setup helpers under `bin/setup/`
- the `kt` shell wrapper from `k-lab.sh`

It has only been tested on an openSUSE Tumbleweed host so far.

For upstream `ktest.pl` syntax and behavior, start with:

- [sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf)
- [Examples](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples)
- [Tutorial](<https://elinux.org/images/f/fd/Automated_Testing_with_ktest.pl_(Embedded_Edition).pdf>)

## Quick Start

`setup.conf` is the machine-local file for this checkout. It only needs:

- `LINUX_GIT`
- `THIS_DIR`

Optional `CROSS_COMPILE_*` and `CHROOT_*` overrides may also be set there (globally for this machine/checkout), or set directly within the test configuration files under `tests/` (test-locally).
Optional `TEST_DIRS` may be set to a colon-separated list of extra test roots
for `kt` lookup and tab completion.

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh`.
3. Build the matching static busybox for the arch you want to boot, for example
   `./bin/setup/build-busybox x86_64`.
4. Source the wrapper:

   ```bash
   source /path/to/k-lab.sh
   ```

5. From inside a Linux kernel worktree, run `kt`.

`setup.sh` clones `tools/virtme-ng` and links `tools/ktest` to
`$LINUX_GIT/tools/testing/ktest`.

Examples:

```bash
# run the default build config and refresh compile_commands.json (build
# only, no boot, so no ROOT_DISK is needed)
kt

# boot a disk image and run the smoke test's boot check
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D TEST:=boot smoke/test

# don't clean the current $OUTPUT_DIR, but force a defconfig
kt -C -D BUILD_TYPE=defconfig

# specify target and host compiler overrides and ssh port to use
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D CC:=gcc-13 -D VNG_PORT:=22001 -D TEST:=boot smoke/test

# boot a foreign-arch disk image; ARCH is inferred from its filename
# (aarch64.img/arm64.img -> arm64, s390x.img -> s390, ppc64le.img -> powerpc)
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/aarch64.img -D TEST:=boot smoke/test

# build inside a target rootfs's own chroot (CHROOT_BUILD), using its own
# native toolchain (foreign arch transparently emulated via qemu-user), then
# boot a matching disk image
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/aarch64.img \
   -D CHROOT:=/roots/suse/Tumbleweed/aarch64 -D CHROOT_BUILD=1 -D TEST:=chroot-boot smoke/test

# build a tumbleweed kernel
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D TEST:=suse-only -D BRANCH:=stable

# also refresh compile_commands.json after the build
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D COMPILE_COMMANDS:=1 -D TEST:=boot smoke/test
```

Wrapper options:

- `-C` sets `BUILD_NOCLEAN=1`
- `-D name=value` passes a normal `ktest.pl` override
- `-D name:=value` overrides a file-scoped parse-time variable such as
  `ROOT_DISK`, `ARCH`, `VNG_PORT`, `TEST`, `CHROOT`, or `CROSS_COMPILE`. `kt`
  itself only actively rejects (with an error) a plain `-D name=value` for
  `ROOT_DISK`, `ARCH`, and `VNG_PORT`; passing `TEST`, `CHROOT`, or
  `CROSS_COMPILE` without `:=` is not caught by `kt` and silently resolves to
  an empty value instead of erroring, so always use `:=` for these six.
- `-n` prints the resolved config and exits

Before a real run, `kt` does its own `ktest.pl --dry-run`, preflights
resolved `ROOT_DISK` and `CHROOT` values (asking for confirmation before a
run that boots a disk image or builds inside a chroot), prompts before
reusing a stale kernel `.config` left over in `OUTPUT_DIR` from a prior
`oldconfig` run, and creates `TMP_DIR.lock` so two runs do not reuse the same
output directory.

Run artifacts live under `tmp/$KLAB_ID`: `kt` derives `KLAB_ID` as a stable
per-test hash of the test's path plus its resolved `ROOT_DISK`/`ARCH` (so
distinct tests, or the same test with a different disk/arch, never share a
TMP_DIR; NOT derived from `TEST`, `CHROOT`, or `CHROOT_BUILD` -- runs that
differ only in one of those currently do share a TMP_DIR). Direct `ktest.pl`
invocations that bypass `kt` fall back to `tmp/$VNG_PORT` instead. The kernel
tree also gets convenience links keyed by `$VNG_PORT` regardless of
`KLAB_ID`, such as `tmp-$VNG_PORT` and `ssh-$VNG_PORT`. Plain `kt` refreshes
`compile_commands.json` by default; named tests only do so when
`COMPILE_COMMANDS=1`. The symlink points at
`compile_commands-$ARCH-$VNG_PORT.json`.

## Dependencies

In openSUSE Tumbleweed, the following packages should be enough (with the
exception of armhf cross toolchain):

```
zypper install \
	-t pattern devel_basis

zypper install \
	bzip2 \
	cross-aarch64-gcc15 \
	cross-ppc64le-gcc15 \
	cross-s390x-gcc15 \
	cross-riscv64-gcc15 \
	python3-argcomplete \
	python3-requests \
	qemu-arm \
	qemu-extra \
	qemu-linux-user \
	qemu-ppc \
	qemu-s390x \
	sudo
```

If you build for a non-native `ARCH` on the host, the host also needs a usable
cross toolchain. By default, k-lab derives `CROSS_COMPILE` from `ARCH`;
`setup.conf` may override that with `CROSS_COMPILE_*`.

k-lab does not check or install packages into `ROOT_DISK`: the disk image is
assumed to already be fully set up with whatever a test needs before you
point `ROOT_DISK` at it.

## Writing Tests

`include/defaults.conf` is the shared base layer stack. Most new tests should
include it and then define only the test-local pieces they care about, as
`tests/smoke` does.

Tests live in their own subdirectory (`tests/<name>/test`), so `INCLUDE`
paths are relative to that directory (`../../include/...`).

Minimal shape:

```conf
INCLUDE ../../include/defaults.conf

DEFAULTS OVERRIDE
BUILD_TYPE = defconfig
ADD_CONFIG = ${CONFIG_DIR}/my.config

TEST_START
TEST_TYPE = test
TEST_BIN = ./my-test.sh
TEST = ${DO_TEST_SIMPLE}
```

For BPF selftests, also include `include/selftests-bpf.conf` after
`defaults.conf`: it installs the `bpf` collection during the build and
prepares the guest to run `test_progs` from the install tree, so a test only
needs to pick a `TEST_BIN`:

```conf
INCLUDE ../../include/defaults.conf
INCLUDE ../../include/selftests-bpf.conf

TEST_START
TEST_TYPE = test
TEST_BIN = ./test_progs -vv -t <subtest>
TEST = ${DO_TEST_SIMPLE}
```

Use `:=` only for parse-time values that affect file composition or derived
paths:

- `ROOT_DISK`
- `ARCH`
- `VNG_PORT`
- `TEST`
- `CHROOT` (and its per-arch `CHROOT_*` inputs)
- `CROSS_COMPILE` (and its per-arch `CROSS_COMPILE_*` inputs; unused when
  `CHROOT_BUILD=1`, since the chroot uses its own native toolchain instead)

Do not set those parse-time variables inside `TEST_START`.

Use `=` for normal runtime options such as:

- `BUILD_TYPE`
- `ADD_CONFIG`
- `CC`
- `HOSTCC`
- `HOSTCFLAGS`
- `VNG_MEM`
- `VNG_ARGS`
- `CHROOT_BUILD`
- `PREP_TEST`
- `POST_BUILD_APPEND`

Unlike the `:=` list above, `CC`, `HOSTCC`, `HOSTCFLAGS`, `CHROOT_BUILD`, and
`VNG_MEM` are resolved lazily, per test, at run time, so they work correctly
whether set at top level or inside a specific `TEST_START` block.

Useful helpers from `include/patterns.conf`:

- `DO_TEST_SIMPLE`: pass or fail on `TEST_BIN` exit status
- `DO_TEST_PATTERN_OK`: pass only if `PATTERN` appears in the captured output
- `DO_TEST_PATTERN_FAIL`: pass only if `PATTERN` does not appear in the
  captured output

If `PREP_TEST` is set, it is inserted before `TEST_BIN` in the same shell
command, so it must end with `&&` or `;`.

For hooks, keep it simple:

- use `*_APPEND` for test-local extra work
- replace a full `PRE_*` or `POST_*` phase only when you intentionally want to
  own the whole phase

# SUSE specifics

`include/suse.conf` is part of the default stack and provides the shared SUSE
selectors `suse` and `suse-only`. Both use
`useconfig:${KSOURCE_GIT}/${BRANCH}/config/<SUSE arch>/default`; `suse-only` also
clears `ADD_CONFIG`. To use them, define `BRANCH` in the test file (required).
`VERSION` and `PATCHLEVEL` are optional and must be set together or not at
all: set both to target a specific SLE product/patchlevel, or leave both
unset to default to openSUSE Tumbleweed. The matching SUSE pre-ktest hook
(`hooks/suse/pre-ktest`) writes the minimal config fragment for the selected
product version.

## Disk Images and Privileges

Set `ROOT_DISK := /path/to/disk.img` to boot that disk image via
virtme-ng's `--root-disk` instead of sharing the host filesystem.
`ROOT_DISK` must be a regular file (a raw or qcow2-style image with an ext4
filesystem inside); k-lab does not support pointing `ROOT_DISK` at a
directory.

If `ARCH` is not set explicitly (and no `--arch` is forwarded via
`VNG_ARGS`), it is inferred from `ROOT_DISK`'s filename: `aarch64.img`/
`arm64.img` -> `arm64`, `s390x.img` -> `s390`, `ppc64le.img`/`ppc64.img` ->
`powerpc`, etc. `ROOT_DISK` may be left unset (the default, `0`) for
build-only tests that never boot a VM; any test that actually boots always
requires it.

VM boots always use a matching static busybox build. Build it first, for
example `./bin/setup/build-busybox x86_64` or
`./bin/setup/build-busybox arm64`.

k-lab does not check or install packages into `ROOT_DISK`; provision the
image with whatever a test needs ahead of time. Disk images can be built
with tools such as [kiwi](https://osinside.github.io/kiwi/), `virt-builder`,
or by converting an existing cloud image -- they just need to be a plain
ext4 filesystem virtme-ng can mount directly.

### Building inside a target root filesystem (chroot)

By default, builds happen on the host with the resolved `CROSS_COMPILE`
toolchain (empty for native `x86_64`, otherwise the matching
`cross-*-gcc*` package or a `CROSS_COMPILE_*` override). Set
`CHROOT_BUILD = 1` plus `CHROOT := /path/to/rootfs` (a directory) to
instead build inside that rootfs via a real `chroot`, using that rootfs's
own native toolchain (its own `gcc`, `make`, headers and libraries) -- the
same compiler that produced the actual target distro, not just a
cross-compiler pointed at its headers. Foreign arches are transparently
emulated by the host's `qemu-user`/`binfmt_misc` registration (already
required for `qemu-linux-user`, see Dependencies), so `CHROOT` can be any
arch regardless of the host's own.

If `ARCH` is not set explicitly and cannot be inferred from `ROOT_DISK`'s
filename, and an explicit `-D CHROOT:=...` was given, `ARCH` is inferred by
inspecting a real ELF binary under `CHROOT` (e.g. its `/bin/sh`) -- `CHROOT`
directories have no naming convention to rely on, unlike `ROOT_DISK`'s
filename.

Every build run gets its own private, writable overlay over `CHROOT`
(`lowerdir=CHROOT`, per-run `upperdir`/`workdir` under `TMP_DIR`), so
concurrent runs sharing the same `CHROOT` (e.g. a shared `CHROOT_ARM64` in
`setup.conf`) never mount, chroot into, or write to the same path, and
`CHROOT` itself is never modified. `BUILD_DIR` and `OUTPUT_DIR` are
bind-mounted into that overlay at matching paths so the chrooted build reads
the same kernel source tree and writes to the same `OUTPUT_DIR` as the rest
of the run.

Like `CROSS_COMPILE_*`, `CHROOT_*` overrides may be set per-arch in
`setup.conf` (`CHROOT_X86_64`, `CHROOT_ARM64`, `CHROOT_ARM`,
`CHROOT_POWERPC`, `CHROOT_S390`, `CHROOT_RISCV`) so `CHROOT` is picked
automatically from `ARCH`; `-D CHROOT:=...` overrides that for a single run.
`CHROOT` is unrelated to `ROOT_DISK`: the same rootfs directory used as a
build chroot is not, and does not need to be, related to the disk image
booted at test time.

`bin/setup/debootstrap` is a small helper for Debian rootfs creation:

```bash
sudo ./bin/setup/debootstrap -s trixie -a arm64 /roots/debian/trixie/arm64
```

`bin/setup/suse-bootstrap` is a small helper for Tumbleweed rootfs creation
(only for native architecture):

```bash
sudo env ROOT=/roots/tumbleweed ./bin/setup/suse-bootstrap
sudo env ROOT=/roots/tumbleweed EXTRA="libstdc++6" ./bin/setup/suse-bootstrap < /tmp/custom-sles-repos
```

(These two helpers use their own `ROOT` env var for their own target path,
unrelated to k-lab's `ROOT_DISK`/`CHROOT`. Their output is a directory,
suitable for `CHROOT` -- not for k-lab's own `ROOT_DISK`, which must be a
disk image.) Other rootfs-directory options include
[pacstrap](https://wiki.archlinux.org/title/Pacstrap),
[alpine-make-rootfs](https://github.com/alpinelinux/alpine-make-rootfs),
[mkosi](https://github.com/systemd/mkosi), etc.

### Privileges

Runtime privilege escalation is centralized in `bin/run`, which uses `sudo -n`
(optionally with `--preserve-env=VAR[,VAR...]`, forwarded to sudo's own
`--preserve-env`). There is no interactive fallback. In practice that covers:

- the `vng` invocation itself (which needs to run as root to manage the
  qemu process) and a best-effort `pkill` cleanup call in `bin/vng/stop-vm`
- `mount`/`umount`/`chroot`, only when `CHROOT_BUILD=1` (see `bin/chroot/*`):
  mounting the per-run overlay and bind mounts, and entering the chroot
  itself. The actual build inside the chroot immediately drops back to the
  invoking user's uid/gid (`chroot --userspec=uid:gid`); only the mount and
  `chroot(2)` syscalls themselves run as real root.

For the built-in flows, the expected sudoers allowlist is:

- the `vng` binary under `tools/virtme-ng` (resolve the symlink to its real
  path for the sudoers entry)
- `/usr/bin/pkill`
- `/usr/bin/mount`, `/usr/bin/umount`, `/usr/bin/chroot` (only needed if you
  use `CHROOT_BUILD`)

The `vng` entry needs a `SETENV:` tag (or an equivalent `Defaults
!env_reset`/`env_keep` override) so that `bin/run --as-root
--preserve-env=PATH,HOME -- vng ...` actually preserves `PATH`/`HOME` under
sudo: `vng` relies on `PATH` to find its own sibling tools (e.g.
`virtme/guest/bin`), and on a per-run `HOME` so concurrent boots' SSH host
key caches never collide. `mount`/`umount`/`chroot` need no such tag.

Some setup helpers also use `sudo`; keep that in mind when preparing a new
host.

## Project Layout

- `include/`: shared config fragments
- `tests/`: top-level test targets and selftest wrappers
- `hooks/`: scripts used by `PRE_*` and `POST_*` phases
- `bin/`: runtime helpers used by generated `ktest.pl` commands
- `bin/setup/`: setup-time helpers
- `config/`: extra kernel config fragments
- `tools/`: repo-local tool state
