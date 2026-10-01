# k-lab

`k-lab` is a thin layer over `ktest.pl` for local kernel build/boot/test loops
with `virtme-ng`. `ktest.pl` stays the control plane and `virtme-ng` is the VM
backend. A test either builds only, or builds and boots the fresh kernel in a VM
against a disk image (`ROOT_DISK`) that supplies the guest userspace.

For upstream `ktest.pl` syntax and behavior, see
[sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf),
the [examples](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples),
and this [tutorial](<https://elinux.org/images/f/fd/Automated_Testing_with_ktest.pl_(Embedded_Edition).pdf>).

## Quick Start

`setup.conf` is the machine-local config for this checkout. Required:

- `LINUX_GIT` — kernel worktree whose `tools/testing/ktest/ktest.pl` drives runs
- `THIS_DIR` — absolute path to this checkout

Optional in `setup.conf`: `KSOURCE_GIT` (SUSE configs), `TEST_DIRS`
(colon-separated extra test roots for `kt` lookup and completion; relative
paths resolve from `THIS_DIR`), and direct `CROSS_COMPILE` / `CHROOT` settings. `CROSS_COMPILE` and `CHROOT` can also be set per test under `tests/`.

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh` — clones `tools/virtme-ng` and links `tools/ktest` to
   `$LINUX_GIT/tools/testing/ktest`.
3. Build a static busybox for each arch you boot, e.g.
   `./bin/setup/build-busybox x86_64`.
4. `source /path/to/k-lab.sh`.
5. From inside a kernel worktree, run `kt`.

### Examples

```bash
# default build config: build only (no boot), refresh compile_commands.json
kt

# boot smoke/test's default ROOT_DISK (Tumbleweed x86_64) and run its boot check
kt -D TEST:=boot smoke/test

# reuse the current OUTPUT_DIR (no clean) but force a defconfig
kt -C -D BUILD_TYPE=defconfig

# override target/host compiler and ssh port
kt -D CC=gcc-13 -D VNG_PORT:=22001 -D TEST:=boot smoke/test

# boot a foreign-arch image for one run
kt -D ARCH:=arm64 -D ROOT_DISK:=/roots/suse/Tumbleweed/aarch64.img -D TEST:=boot smoke/test

# build inside a target rootfs's own chroot, then boot a matching image
kt -D CHROOT:=/roots/suse/Tumbleweed/aarch64 -D CHROOT_BUILD=1 \
   -D ROOT_DISK:=/roots/suse/Tumbleweed/aarch64.img -D TEST:=chroot-boot smoke/test

# build an openSUSE Tumbleweed kernel config
kt -D TEST:=suse-only -D BRANCH:=stable
```

### Wrapper options

- `-C` — set `BUILD_NOCLEAN=1`
- `-D name=value` — pass a normal `ktest.pl` runtime override
- `-D name:=value` — override a parse-time variable (`ROOT_DISK`, `ARCH`,
  `VNG_PORT`, `TEST`, `CHROOT`, `CROSS_COMPILE`)
- `-n` — print the resolved config and exit
- `-y` — non-interactive
- `-h` — help

With no test argument, `kt` runs `include/defaults.conf`. Test names tab-complete
from `tests/` and `TEST_DIRS`.

**Always use `:=` for those six parse-time variables on the command line.** `kt`
rejects a plain `-D ROOT_DISK=`, `-D ARCH=`, or `-D VNG_PORT=` with an error,
but does *not* catch `-D TEST=`, `-D CHROOT=`, or `-D CROSS_COMPILE=` — those
are silently ignored and your override never takes effect. Prefer setting
`ROOT_DISK` in the test file (see [Writing Tests](#writing-tests)); use the flag
only for one-off overrides.

### What a run does

Before each real run, `kt` runs its own `ktest.pl --dry-run` to resolve the
config, then:

- preflights the resolved `ROOT_DISK`/`CHROOT` and asks for confirmation before
  booting a disk image or building in a chroot;
- prompts before an `oldconfig` build reuses a stale `.config` already in
  `OUTPUT_DIR` (continue / wipe to defconfig / abort);
- picks a free `VNG_PORT` and creates `<TMP_DIR>.lock` so two runs never share
  an output directory.

Artifacts live under `tmp/$KLAB_ID`, where `KLAB_ID` is a stable hash of the
test path plus its resolved `ROOT_DISK`/`ARCH`. So different tests — or the same
test on a different disk/arch — never share a `TMP_DIR`. It is **not** keyed on
`TEST`, `CHROOT`, or `CHROOT_BUILD`, so runs differing only in those *do* share
one. Direct `ktest.pl` runs that bypass `kt` fall back to `tmp/$VNG_PORT`. The
kernel tree also gets `tmp-$VNG_PORT` and `ssh-$VNG_PORT` convenience links.

`compile_commands.json` is refreshed automatically for a bare `kt`, and for
named tests only with `COMPILE_COMMANDS=1`; the symlink points at
`compile_commands-$ARCH-$VNG_PORT.json`.

## Dependencies

On openSUSE Tumbleweed the following should be enough (armhf cross toolchain
excepted):

```
zypper install -t pattern devel_basis
zypper install \
	bzip2 cross-aarch64-gcc15 cross-ppc64le-gcc15 cross-s390x-gcc15 \
	cross-riscv64-gcc15 debootstrap fakeroot python3-argcomplete \
	python3-requests qemu-arm qemu-extra qemu-linux-user qemu-ppc \
	qemu-s390x sudo
```

Building for a non-native `ARCH` on the host needs a matching cross toolchain;
k-lab derives `CROSS_COMPILE` from `ARCH` unless `setup.conf` overrides it.
`sudo` is used in exactly one place — `build-busybox` runs `sudo zypper install`
to pull in a missing cross-compiler or `glibc-devel` package (only when
`rpm`/`zypper` are present and the package is absent); nothing else in the repo
uses it.

## Writing Tests

`include/defaults.conf` is the shared base stack. Most tests `INCLUDE` it and
then define only their test-local pieces (see `tests/smoke`). Each test lives in
`tests/<name>/test`, so `INCLUDE` paths are relative to that directory
(`../../include/...`).

```conf
# ROOT_DISK := /path/to/x86_64.img   # only if the test boots a VM

INCLUDE ../../include/defaults.conf

DEFAULTS OVERRIDE
BUILD_TYPE = defconfig
ADD_CONFIG = ${CONFIG_DIR}/my.config

TEST_START
TEST_TYPE = test
TEST_BIN = ./my-test.sh
TEST = ${DO_TEST_SIMPLE}
```

If a test boots a VM, set `ROOT_DISK := ...` before `INCLUDE` so a bare
`kt <dir>/<file>` reproduces the run on its own; reserve `-D ROOT_DISK:=...` for
one-off overrides (e.g. the same test against a different image or arch).

### Parse-time (`:=`) vs runtime (`=`)

Use `:=` for parse-time variables that affect file composition or derived paths.
Set them at the top level, **never inside `TEST_START`**:

- `ROOT_DISK`, `ARCH`, `VNG_PORT`, `TEST`
- `CHROOT`
- `CROSS_COMPILE` (unused when
  `CHROOT_BUILD=1`, since the chroot uses its own native toolchain)

Use `=` for normal runtime options: `BUILD_TYPE`, `ADD_CONFIG`, `CC`, `HOSTCC`,
`HOSTCFLAGS`, `VNG_MEM`, `VNG_ROOT_DEV`, `VNG_ROOT_FSTYPE`, `VNG_ARGS`,
`CHROOT_BUILD`, `PREP_TEST`, `POST_BUILD_APPEND`, … Of these, `CC`, `HOSTCC`, `HOSTCFLAGS`, `CHROOT_BUILD`,
and `VNG_MEM` are resolved lazily per test, so they work whether set at the top
level or inside a specific `TEST_START` block.

### Test helpers (`include/patterns.conf`)

- `DO_TEST_SIMPLE` — pass/fail on `TEST_BIN`'s exit status
- `DO_TEST_PATTERN_OK` — pass only if `PATTERN` appears in the captured output
- `DO_TEST_PATTERN_FAIL` — pass only if `PATTERN` does not appear

The `PATTERN_*` macros key off the captured log text only and do **not** preserve
`TEST_BIN`'s exit status; escape quotes inside `PATTERN` (`'` → `'\''`). If
`PREP_TEST` is set it is inserted before `TEST_BIN` in the same shell command,
so it must end with `&&` or `;`.

### Hooks

- use `*_APPEND` for test-local extra work
- replace a full `PRE_*`/`POST_*` phase only when you intend to own the whole
  phase

### BPF selftests

Include `include/selftests-bpf.conf` after `defaults.conf`: it installs the
`bpf` collection during the build and prepares the guest to run `test_progs`
from the install tree, so the test only needs to pick a `TEST_BIN`. The build
environment (host, or `CHROOT` when `CHROOT_BUILD=1`) must already provide the
bpf build deps (clang, lld, llvm(+-dev), dwarves, libdwarf, a C++ compiler,
python3-docutils, xxd); k-lab does not install them.

```conf
INCLUDE ../../include/defaults.conf
INCLUDE ../../include/selftests-bpf.conf

TEST_START
TEST_TYPE = test
TEST_BIN = ./test_progs -vv -t <subtest>
TEST = ${DO_TEST_SIMPLE}
```

## SUSE specifics

`include/suse.conf` (part of the default stack) provides the `suse` and
`suse-only` selectors. Both build with
`useconfig:${KSOURCE_GIT}/${BRANCH}/config/<SUSE arch>/default`; `suse-only`
also clears `ADD_CONFIG`. `BRANCH` is required: set it in the test file, or via
`-D` as in the Quick Start example. `VERSION` and `PATCHLEVEL` are optional and
must be set together: set both to target a specific SLE product/patchlevel, or
leave both unset for openSUSE Tumbleweed.
`hooks/suse/pre-ktest` writes the matching config fragment.

## Disk Images and Privileges

Any test that boots a VM requires a `ROOT_DISK`: k-lab always boots the freshly
built kernel against a disk image via virtme-ng's `--root-disk` (there is no
host-filesystem-share boot mode), and that image supplies the guest userspace.
Set `ROOT_DISK := /path/to/disk.img` — a regular file (a raw or qcow2-style
image with an ext4 filesystem inside), never a directory. The defaults
(`VNG_ROOT_DEV = /dev/vda`, `VNG_ROOT_FSTYPE = ext4`) suit a plain
single-partition ext4 image; set `VNG_ROOT_DEV` and `VNG_ROOT_FSTYPE` in the
test file when the image uses a different layout (e.g. a partitioned btrfs
image with root on `/dev/vda3`). Leave it unset (the
default, `0`) only for build-only tests that never boot. k-lab does not provision
the image — set it up with everything a test needs beforehand, e.g. with
[kiwi](https://osinside.github.io/kiwi/), `virt-builder`, or a converted cloud
image; it just needs a plain ext4 filesystem virtme-ng can mount.

`ARCH` defaults to the host architecture. Set it explicitly for another target; neither
disk names nor chroot binaries determine the architecture.

Every VM boot needs a matching static busybox; build it first, e.g.
`./bin/setup/build-busybox x86_64`.

### Building inside a target rootfs (chroot)

By default builds run on the host with the resolved `CROSS_COMPILE` toolchain
(empty for native `x86_64`). Set `CHROOT_BUILD = 1` plus `CHROOT :=
/path/to/rootfs` (a directory) to instead build inside that rootfs via a real
`chroot`, using its own native toolchain — the compiler that actually produced
the target distro, not a cross-compiler pointed at its headers. This is handy
when an older kernel needs an older compiler shipped only in an older rootfs.
Foreign arches run transparently via the host's `qemu-user`/`binfmt_misc`, so
`CHROOT` can be any arch.

Each make command runs in its own unprivileged user, mount, and PID
namespace. It mounts a writable overlay over `CHROOT`, with upper/work
directories under `TMP_DIR`, and binds in `BUILD_DIR` and `OUTPUT_DIR`.
The overlay changes persist across commands; mounts disappear when the command
exits. `CHROOT` itself is never modified.

`CHROOT` is independent of `ROOT_DISK`; the build directory and guest image
need not be from the same distro. Set `ARCH` explicitly for foreign chroots.

#### Creating rootfs directories

`bin/setup/debootstrap` (Debian) and `bin/setup/suse-bootstrap` (Tumbleweed,
native arch only) build rootfs directories usable as `CHROOT`, fully
unprivileged:

```bash
./bin/setup/debootstrap -s trixie -a arm64 /roots/debian/trixie/arm64
env ROOT=/roots/tumbleweed ./bin/setup/suse-bootstrap
```

Both take their own target path (their `ROOT`/argument, unrelated to k-lab's
`ROOT_DISK`/`CHROOT`) and produce a directory, not a disk image. Package
extraction runs under `fakeroot`; `debootstrap`'s real `chroot(2)` steps run in
an unprivileged mapped-root user namespace. Both leave files owned by the
invoking user on disk (only fake-owned as root) — fine for a `CHROOT`; use
`fakeroot -s`/`-i <statefile>` or a real-root `chown -R root:root` pass only if
shipping the rootfs elsewhere. `debootstrap` has one further gap: a chrooted
postinst or `-e` command that `chown`s to some *other* non-root id is not covered
(its chroot phase maps only your uid to `0`). Other options include
[pacstrap](https://wiki.archlinux.org/title/Pacstrap),
[alpine-make-rootfs](https://github.com/alpinelinux/alpine-make-rootfs), and
[mkosi](https://github.com/systemd/mkosi).

### Privileges

Nothing in k-lab's runtime or setup needs real root, `sudo`, or a privileged
daemon, except `build-busybox` optionally running `sudo zypper install` for a
missing cross toolchain (see [Dependencies](#dependencies)):

- `vng` boots as the invoking user; QEMU usermode networking and `--root-disk`
  need no host privileges.
- `debootstrap` and `suse-bootstrap` run under `fakeroot` (plus, for
  `debootstrap`'s `chroot(2)` steps, an unprivileged mapped-root user namespace).
- `CHROOT_BUILD=1` mounts and chroots inside an **unprivileged user namespace**
  (the same approach as rootless Podman/Buildah/bubblewrap), never real root.

Requirements: unprivileged user namespaces enabled (default on most distros;
otherwise `sysctl kernel.unprivileged_userns_clone=1`), a reasonably recent
`util-linux` (2.42.1 tested), and `CHROOT` owned by the invoking user.

Caveat: chrooted builds see uid/gid `0` inside the chroot (never real root, only
the invoking user mapped to `0`), so a build that branches on
`[ "$(id -u)" = 0 ]` may behave differently than on the host.

## Project Layout

- `include/` — shared config fragments
- `tests/` — test targets and selftest wrappers
- `hooks/` — scripts run in `PRE_*`/`POST_*` phases
- `bin/` — runtime helpers used by generated `ktest.pl` commands
- `bin/setup/` — setup-time helpers
- `config/` — extra kernel config fragments
- `tools/` — repo-local tool state (ktest link, virtme-ng, busybox)
