# k-lab

`k-lab` is a thin layer on top of `ktest.pl` for local kernel build, boot, and
test loops with `virtme-ng`.

It keeps `ktest.pl` as the control plane, uses `virtme-ng` as the VM backend,
and can also run builds and tests against an external root filesystem instead
of the host.

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

Optional `CROSS_COMPILE_*` overrides may also be set there.
Optional `TEST_DIRS` may be set to a colon-separated list of extra test roots
for `kt` lookup and tab completion.

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh`.
3. Build the matching static busybox and QEMU for the arch you want to boot,
   and the virtiofsd daemon, for example:
   `./bin/setup/build-busybox x86_64`,
   `./bin/setup/build-qemu x86_64`,
   `./bin/setup/build-virtiofsd`.
4. Source the wrapper:

   ```bash source /path/to/k-lab.sh ```

5. From inside a Linux kernel worktree, run `kt`.

`setup.sh` clones `tools/virtme-ng` and links `tools/ktest` to
`$LINUX_GIT/tools/testing/ktest`.

Examples:

```bash
# run the default build config and refresh compile_commands.json
kt

# run the minimal vng test config
kt vng

# build and run all net selftests
kt -D TEST:=all selftests/net

# don't clean the current $OUTPUT_DIR, but force a defconfig
kt -C -D BUILD_TYPE=defconfig

# specify target and host compiler overrides and ssh port to use
kt -D CC:=gcc-13 -D VNG_PORT:=22001 vng

# build with CROSS_COMPILE_RISCV (auto-detect arch from rootfs)
# run the tests within ROOT
kt -D ROOT:=/roots/debian/trixie/riscv64 selftests/net

# build with the rootfs compiler (binfmt_misc)
kt -D ROOT:=/roots/debian/sid/arm64 -D BUILD_IN_ROOT:=1

# build a tumbleweed kernel
kt -D ROOT:=/roots/tumbleweed -D TEST:=suse-only -D BRANCH:=stable

# also refresh compile_commands.json after the build
kt -D COMPILE_COMMANDS:=1 vng
```

Wrapper options:

- `-C` sets `BUILD_NOCLEAN=1`
- `-D name=value` passes a normal `ktest.pl` override
- `-D name:=value` overrides a file-scoped parse-time variable such as `ROOT`,
  `ARCH`, `VNG_PORT`, or `TEST`
- `-n` prints the resolved config and exits

Before a real run, `kt` does its own `ktest.pl --dry-run`, preflights resolved
`ROOT` values, asks before reusing a `TMP_DIR` that already contains `kt.log`,
and creates `TMP_DIR.lock` so two runs do not reuse the same output directory.

Run artifacts live under `tmp/$VNG_PORT`. The kernel tree also gets convenience
links such as `tmp-$VNG_PORT` and `ssh-$VNG_PORT`. Plain `kt` refreshes
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
	sudo \
	meson \
	ninja \
	pkg-config \
	glib2-devel
```

`bin/setup/build-virtiofsd` also needs a Rust toolchain (`cargo`/`rustc`), for
example via [rustup](https://rustup.rs/).

If you build for a non-native `ARCH` on the host, the host also needs a usable
cross toolchain. By default, k-lab derives `CROSS_COMPILE` from `ARCH`;
`setup.conf` may override that with `CROSS_COMPILE_*`.

k-lab does not check or install packages into `ROOT`: the rootfs is assumed
to already be fully set up with whatever a test needs before you point
`ROOT` at it.

## Writing Tests

`include/defaults.conf` is the shared base layer stack. Most new tests should
include it and then define only the test-local pieces they care about, as
`tests/vng` does.

Minimal shape:

```conf
INCLUDE ../include/defaults.conf

DEFAULTS OVERRIDE
BUILD_TYPE = defconfig
ADD_CONFIG = ${CONFIG_DIR}/my.config

TEST_START
TEST_TYPE = test
TEST_BIN = ./my-test.sh
TEST = ${DO_TEST_SIMPLE}
```

Use `:=` only for parse-time values that affect file composition or derived
paths:

- `ROOT`
- `ARCH`
- `VNG_PORT`
- `TEST`

Do not set those parse-time variables inside `TEST_START`.

Use `=` for normal runtime options such as:

- `BUILD_TYPE`
- `ADD_CONFIG`
- `CC`
- `HOSTCC`
- `HOSTCFLAGS`
- `VNG_MEM`
- `VNG_ARGS`
- `BUILD_IN_ROOT`
- `PREP_TEST`
- `POST_BUILD_APPEND`

`CC`, `HOSTCC`, and `HOSTCFLAGS` are currently global build settings. Set them
at top level or with `-D ...`, not inside `TEST_START`.

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
clears `ADD_CONFIG`. To use them, define `VERSION`, `PATCHLEVEL`, and `BRANCH`
in the test file. The matching SUSE pre-ktest hook writes the minimal config
fragment for the selected product version.

## Root Filesystems and Privileges

Set `ROOT := /path/to/rootfs` to run against an external root filesystem
instead of the host.

`ROOT` itself is treated as a read-only, shared base image: every run mounts
its own private, throwaway copy-on-write overlay on top of it (an
`overlayfs` merged view, upper/work dirs under that run's `TMP_DIR`) and
only ever mounts, `chroot`s into, or writes to that private view -- never
`ROOT` directly. This is what makes it safe to point multiple concurrent
runs (e.g. several agents) at the same `ROOT` at once: they never share a
mountpoint, and nothing one run writes (installed packages, kernel modules,
temp files) is visible to another run or persisted back into `ROOT`. Keep
`ROOT` itself provisioned with everything your tests need ahead of time;
k-lab does not modify it.

By default, builds still happen on the host. Set `BUILD_IN_ROOT = 1` if you
want the kernel build to happen inside the rootfs instead.

For foreign-arch roots:

- host-side builds use the resolved `ARCH` plus a host cross toolchain
- host-side execution inside the rootfs still needs `binfmt_misc` plus QEMU
  user-mode support

VM boots always use a matching static busybox build and QEMU binary. Build
them first, for example `./bin/setup/build-busybox x86_64 && ./bin/setup/build-qemu x86_64`
or `./bin/setup/build-busybox arm64 && ./bin/setup/build-qemu arm64`. Also run
`./bin/setup/build-virtiofsd` once (architecture-independent).

`bin/rootfs/shell` is a convenience wrapper around the same mount and `chroot`
path used by normal rootfs-backed runs. It needs `TMP_DIR` set to a scratch
directory (this is where its private overlay lives); use a distinct
`TMP_DIR` per concurrent session against the same `ROOT`:

```bash
ROOT=/roots/debian/trixie/x86_64 TMP_DIR=/tmp/rootfs-shell ./bin/rootfs/shell
ROOT=/roots/debian/trixie/x86_64 TMP_DIR=/tmp/rootfs-shell ./bin/rootfs/shell -- uname -a
```

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

Other options include vng's own `--root` for Ubuntu cloud images,
[pacstrap](https://wiki.archlinux.org/title/Pacstrap),
[alpine-make-rootfs](https://github.com/alpinelinux/alpine-make-rootfs),
[mkosi](https://github.com/systemd/mkosi), etc.

Runtime privilege escalation is centralized in `bin/run`, which uses `sudo -n`
(optionally with `--preserve-env=VAR[,VAR...]`, forwarded to sudo's own
`--preserve-env`). There is no interactive fallback. In practice that covers
the per-run overlay mount, the rootfs mount/umount/chroot helpers, and the
`vng` invocation itself. `ROOT` is expected to be owned by root (uid 0), like
`bin/setup/debootstrap` and `bin/setup/suse-bootstrap` leave it: it is a
shared, read-only base image with a per-run, invoker-owned overlay on top
(see `rootfs_overlay_paths` in `bin/env.sh`), so nothing ever needs to write
into `ROOT` itself.

For the built-in flows, the expected sudoers allowlist is:

- `/usr/bin/chroot`
- `/usr/bin/mount`
- `/usr/bin/umount`
- `/usr/bin/touch`
- the `vng` binary under `tools/virtme-ng` (resolve the symlink to its real
  path for the sudoers entry)

The `vng` entry needs a `SETENV:` tag (or an equivalent `Defaults
!env_reset`/`env_keep` override) so that `bin/run --as-root
--preserve-env=PATH -- vng ...` actually preserves `PATH` under sudo; `vng`
relies on it to find its own sibling tools (e.g. `virtme/guest/bin`) via
`PATH`-based lookups.

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
