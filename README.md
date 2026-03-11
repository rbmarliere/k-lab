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

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh`.
3. Source the wrapper:

   ```bash source /path/to/k-lab.sh ```

4. From inside a Linux kernel worktree, run `kt`.

`setup.sh` populates `tools/virtme-ng` and links `tools/ktest` to
`$LINUX_GIT/tools/testing/ktest`.

Bare `kt` runs `include/defaults.conf`. `kt -n` prints the resolved config and
exits.

With no explicit `BUILD_TYPE`, the default path is `ktest.pl`'s `oldconfig`. If
`$OUTPUT_DIR/.config` already exists, that file is reused; otherwise `ktest.pl`
creates an empty `.config` and runs `olddefconfig`.

Examples:

```bash
kt
kt -D BUILD_TYPE=defconfig
kt nd_tbl
kt -D ROOT:=/roots/debian/trixie/x86_64
kt -D TEST:=progs selftests/bpf
kt -D TEST:=tumbleweed-only selftests/net
kt -D VNG_PORT:=22999 nd_tbl
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
links such as `tmp-$VNG_PORT` and `ssh-$VNG_PORT`, and `hooks/post_build`
refreshes `compile_commands.json` to point at
`compile_commands-$ARCH-$VNG_PORT.json`.

## Host Requirements

`k-lab` itself only assumes:

- a real kernel git worktree at `LINUX_GIT`
- `$LINUX_GIT/tools/testing/ktest/ktest.pl`
- a completed `./setup.sh`

In practice, the host should also have:

- `bash`, `git`, `make`, `python3`, `qemu`, `ssh`, ...
- the dependencies required by `virtme-ng`

If you build for a non-native `ARCH` on the host, the host also needs a usable
cross toolchain. By default, k-lab derives `CROSS_COMPILE` from `ARCH`;
`setup.conf` may override that with `CROSS_COMPILE_*`.

`DEPS` adds test-specific packages on top of the built-in base tool list.
Package names go through the distro-specific maps under `pkg/` when a mapping
exists. Missing packages are auto-installed by default; set `AUTO_INSTALL_DEPS
= 0` if you want missing packages to stay a hard failure.

## Writing Tests

Most new tests should start from `include/defaults.conf` and then override only
the bits they care about.

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
- `DEPS`
- `VNG_MEM`
- `VNG_ARGS`
- `BUILD_IN_ROOT`
- `PREP_TEST`
- `POST_BUILD_APPEND`

`include/defaults.conf` already pulls in the shared default layers. In most
cases you should include `defaults.conf` and stop there.

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

`include/suse.conf` is part of the default stack and provides shared SUSE
selectors such as `suse-no-config`, `tumbleweed`, `sl-16.0`, and `sl-16.1`,
plus their `-only` variants. The matching SUSE pre-ktest hook writes the
minimal config fragment for the selected product.

## Root Filesystems and Privileges

Set `ROOT := /path/to/rootfs` to run against an external root filesystem
instead of the host.

By default, builds still happen on the host. Set `BUILD_IN_ROOT = 1` if you
want the kernel build to happen inside the rootfs instead.

For foreign-arch roots:

- host-side builds use the resolved `ARCH` plus a host cross toolchain
- host-side execution inside the rootfs still needs `binfmt_misc` plus QEMU
  user-mode support
- VM boots also need a matching static busybox build, for example
  `./bin/setup/build-busybox arm64`

`bin/rootfs/shell` is a convenience wrapper around the same mount and `chroot`
path used by normal rootfs-backed runs:

```bash
ROOT=/roots/debian/trixie/x86_64 ./bin/rootfs/shell
ROOT=/roots/debian/trixie/x86_64 ./bin/rootfs/shell -- uname -a
```

`bin/setup/debootstrap` is a small helper for Debian rootfs creation:

```bash
./bin/setup/debootstrap -s trixie -r /roots/debian/trixie/arm64 -a arm64
```

Runtime privilege escalation is centralized in `bin/run`, which uses `sudo -n`.
There is no interactive fallback. In practice that covers package installation
plus the rootfs mount, umount, and `chroot` helpers. For the current
`virtme-ng` path, `ROOT` should therefore point at a rootfs tree owned by the
calling uid, not just a directory that happens to be readable and writable.

For the built-in flows, the expected sudoers allowlist is:

- `/usr/bin/chroot`
- `/usr/bin/mount`
- `/usr/bin/umount`
- `/usr/bin/apt` on Debian or Ubuntu systems
- `/usr/bin/zypper` on SUSE or openSUSE systems

Some setup helpers also use `sudo`; keep that in mind when preparing a new
host.

## Project Layout

- `include/`: shared config fragments
- `tests/`: top-level test targets and selftest wrappers
- `hooks/`: scripts used by `PRE_*` and `POST_*` phases
- `bin/`: runtime helpers used by generated `ktest.pl` commands
- `bin/setup/`: setup-time helpers
- `config/`: extra kernel config fragments
- `pkg/`: distro-specific package name maps
- `tools/`: repo-local tool state
