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

Optional `CROSS_COMPILE_*` overrides may also be set there.
Optional `TEST_DIRS` may be set to a colon-separated list of extra test roots
for `kt` lookup and tab completion.

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh`.
3. Build the matching static busybox for the arch you want to boot, for example
   `./bin/setup/build-busybox x86_64`.
4. Source the wrapper:

   ```bash source /path/to/k-lab.sh ```

5. From inside a Linux kernel worktree, run `kt`.

`setup.sh` clones `tools/virtme-ng` and links `tools/ktest` to
`$LINUX_GIT/tools/testing/ktest`.

Examples:

```bash
# run the default build config and refresh compile_commands.json (build
# only, no boot, so no ROOT_DISK is needed)
kt

# run the minimal vng test config, booting a disk image
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img vng

# build and run all net selftests
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D TEST:=all selftests/net

# don't clean the current $OUTPUT_DIR, but force a defconfig
kt -C -D BUILD_TYPE=defconfig

# specify target and host compiler overrides and ssh port to use
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D CC:=gcc-13 -D VNG_PORT:=22001 vng

# boot a foreign-arch disk image; ARCH is inferred from its filename
# (aarch64.img/arm64.img -> arm64, s390x.img -> s390, ppc64le.img -> powerpc)
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/aarch64.img vng

# build a tumbleweed kernel
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D TEST:=suse-only -D BRANCH:=stable

# also refresh compile_commands.json after the build
kt -D ROOT_DISK:=/roots/suse/Tumbleweed/x86_64.img -D COMPILE_COMMANDS:=1 vng
```

Wrapper options:

- `-C` sets `BUILD_NOCLEAN=1`
- `-D name=value` passes a normal `ktest.pl` override
- `-D name:=value` overrides a file-scoped parse-time variable such as `ROOT_DISK`,
  `ARCH`, `VNG_PORT`, or `TEST`
- `-n` prints the resolved config and exits

Before a real run, `kt` does its own `ktest.pl --dry-run`, preflights resolved
`ROOT_DISK` values, asks before reusing a `TMP_DIR` that already contains `kt.log`,
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

- `ROOT_DISK`
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

## Disk Images and Privileges

Set `ROOT_DISK := /path/to/disk.img` to boot that disk image via virtme-ng's
`--root-disk` instead of sharing the host filesystem. `ROOT_DISK` must be a
regular file (a raw or qcow2-style image with an ext4 filesystem inside).

If `ARCH` is not set explicitly (and no `--arch` is forwarded via
`VNG_ARGS`), it is inferred from `ROOT_DISK`'s filename: `aarch64.img`/`arm64.img`
-> `arm64`, `s390x.img` -> `s390`, `ppc64le.img`/`ppc64.img` -> `powerpc`,
etc. `ROOT_DISK` may be left unset (the default, `0`) for build-only tests that
never boot a VM; any test that actually boots always requires it.

VM boots always use a matching static busybox build. Build it first, for
example `./bin/setup/build-busybox x86_64` or
`./bin/setup/build-busybox arm64`.

k-lab does not check or install packages into `ROOT_DISK`; provision the image
with whatever a test needs ahead of time.

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
the rootfs mount/umount/chroot helpers (used by `BUILD_IN_ROOT`) and the
`vng` invocation itself.

For the built-in flows, the expected sudoers allowlist is:

- `/usr/bin/chroot`
- `/usr/bin/mount`
- `/usr/bin/umount`
- the `vng` binary under `tools/virtme-ng` (resolve the symlink to its real
  path for the sudoers entry)

The `vng` entry needs a `SETENV:` tag (or an equivalent `Defaults
!env_reset`/`env_keep` override) so that `bin/run --as-root
--preserve-env=PATH,HOME -- vng ...` actually preserves `PATH`/`HOME` under
sudo: `vng` relies on `PATH` to find its own sibling tools (e.g.
`virtme/guest/bin`), and on a per-run `HOME` so concurrent boots' SSH host
key caches never collide.

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
