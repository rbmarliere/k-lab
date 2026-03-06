# k-lab

`k-lab` is a small layer on top of `ktest.pl` for local kernel build, boot, and test loops using `virtme-ng`.

`ktest.pl` is good at describing repeatable build, install, boot, and test flows with reusable config fragments and per-test overrides, while `virtme-ng` is good at booting a locally built kernel quickly in QEMU. The whole point of this tree is to mix those two together: keep `ktest.pl` as the control plane and use `virtme-ng` as the fast local VM backend. It also gives you a straightforward way to build and run tests against an external root filesystem instead of the host.

This repo does not replace `ktest.pl`. It gives you:

- shared config fragments under `include/`
- shell helpers under `bin/` and `hooks/`
- setup helpers under `bin/setup/`
- a small `kt` wrapper plus Bash completion in `k-lab.sh`
- ready-to-edit test configs under `tests/`
- local tool state under `tools/`

It has only been tested on an openSUSE Tumbleweed host so far. It is still a bit scrappy and very much a work in progress, so treat it as just a handy starting point for your own local `ktest.pl` setup.

For raw `ktest.pl` syntax and behavior, start with:

- [sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf)
- [Examples](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples)
- [Tutorial](https://elinux.org/images/f/fd/Automated_Testing_with_ktest.pl_(Embedded_Edition).pdf)

## Quick Start

`setup.conf` is the machine-local file for this checkout. It only needs:

- `LINUX_GIT`
- `THIS_DIR`

Optional per-arch cross-compiler prefix overrides may also be set there:

- `CROSS_COMPILE_ARM64`
- `CROSS_COMPILE_ARM`
- `CROSS_COMPILE_POWERPC`
- `CROSS_COMPILE_S390`
- `CROSS_COMPILE_RISCV`

`VNG_DIR` is always `${THIS_DIR}/tools/virtme-ng`.

`setup.sh` prepares the mandatory `${THIS_DIR}/tools/` pieces:

- `tools/virtme-ng`: local `virtme-ng` checkout and build
- `tools/ktest`: symlink to `${LINUX_GIT}/tools/testing/ktest` for local reference

Foreign-arch `virtme-ng` runs need one extra explicit step:

- `bin/setup/build-busybox [arch ...]`: local busybox checkout under `tools/busybox`, with static installs under `tools/busybox/$ARCH/`

For Debian rootfs creation, the repo also ships:

- `bin/setup/debootstrap`: convenience helper to create a Debian rootfs tree with k-lab arch names, install `linux-image-generic` and `openssh-server`, and apply the default post-install tweaks
- `bin/rootfs/shell`: convenience helper to mount a `ROOT`, open a shell inside it, or run a command there through the same `chroot` path used by rootfs-backed runs, and unmount on exit

This project is Bash-first: the wrapper and helper scripts assume Bash, and `kt` itself is defined when you source `k-lab.sh`.

Use `:=` for parse-time knobs that affect the include stack or derived paths:

- `ROOT`
- `ARCH`
- `VNG_PORT`

Use `=` for normal runtime options such as `BUILD_IN_ROOT`.

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh`.
3. Source the wrapper:

   ```bash
   source /path/to/k-lab.sh
   ```

   This is the main entrypoint for interactive use, not an optional extra.

4. If you plan to boot a foreign-arch `ROOT`, build the matching static busybox binary:

   ```bash
   ./bin/setup/build-busybox arm64
   ```

   With no arguments it builds all supported foreign arches.

5. Run `kt` from inside a Linux kernel worktree.

Examples:

```bash
# basic build + boot loop
kt vng
kt -n vng

# rootfs-backed runs
# same-arch external rootfs
kt -D ROOT:=/roots/debian/trixie/x86_64 vng

# foreign ROOT, default host-side cross-build
kt -D ROOT:=/roots/suse/Tumbleweed/vm-aarch64 vng

# foreign ROOT, but build with the compiler inside the rootfs
kt -D ROOT:=/roots/suse/Tumbleweed/vm-aarch64 -D BUILD_IN_ROOT=1 vng

# wrapper knobs
# keep missing packages as a hard failure for this run
kt -D AUTO_INSTALL_DEPS=0 vng

# test selection and vng port override
kt -n selftests/net
kt -D VNG_PORT:=22999 nd_tbl
kt -D VNG_MEM=2G vng

# rootfs helpers
ROOT=/roots/debian/trixie/x86_64 ./bin/rootfs/shell
ROOT=/roots/debian/trixie/x86_64 ./bin/rootfs/shell -- uname -a

# quick Debian rootfs bootstrap
./bin/setup/debootstrap -s trixie -r /roots/debian/trixie/arm64 -a arm64
```

Wrapper options:

- `-B` sets `BUILD_TYPE=nobuild`
- `-C` sets `BUILD_NOCLEAN=1`
- `-D name=value` passes a `ktest.pl` option override
- `-D name:=value` overrides a file-scoped parse-time variable such as `ROOT`, `ARCH`, or `VNG_PORT`
- `-n` prints the resolved config and exits

The wrapper also does its own `ktest.pl --dry-run` before a real run, preflights resolved `ROOT` values, asks for confirmation before continuing with `ROOT`-backed runs, asks again before reusing a `TMP_DIR` that already contains `kt.log`, and creates `TMP_DIR.lock` so two runs do not stomp the same output directory.

`MACHINE` and `TMP_DIR` are keyed by `VNG_PORT`, not by `ARCH`. In practice that means work directories look like `tmp/vng_22000`; the arch-specific compile database is exposed separately through `compile_commands-$ARCH.json`.

After a successful build, `hooks/post_build` refreshes `compile_commands.json` in the kernel tree to point at the active `compile_commands-$ARCH.json`.

Other hooks also keep a couple of convenience links up to date in the kernel tree:

- `./ssh` -> the generated `vng.ssh` helper under the active `tmp/` directory
- `./tmp` -> the active run directory such as `tmp/vng_22000`

## Dependencies

`k-lab` itself only checks a few basics:

- `LINUX_GIT` must point at a real kernel git worktree, preferably master and unrelated to the worktree being targeted for testing
- `${LINUX_GIT}/tools/testing/ktest/ktest.pl` must exist
- after `./setup.sh`, `${THIS_DIR}/tools/virtme-ng/vng` must exist
- for foreign-arch `virtme-ng` boots, `./bin/setup/build-busybox $ARCH` must have populated `${THIS_DIR}/tools/busybox/$ARCH/bin/busybox`

In practice, the host should also have:

- `bash`, `binutils`, `git`, `make`, `python3`
- `cargo` and `rustc` for the local `virtme-ng` build
- Python `argcomplete` and `requests` for `virtme-ng`
- QEMU (`qemu-system-*` or `qemu-kvm`), with KVM if you want decent performance
- `sudo` plus `chroot` for `ROOT`-backed runs
- `binfmt_misc` plus QEMU user-mode emulation (`qemu-user`, `qemu-linux-user`, `qemu-user-static`, or distro equivalent) if you want host-side command execution inside a foreign-arch `ROOT`
- `ssh` and `ssh-keygen` on the host, plus `sshd` in the guest or rootfs if you use the SSH flow

`DEPS` is the single test-local dependency knob. k-lab always installs its built-in base tool list, and `DEPS` adds to that list for the current test. Missing packages are auto-installed by default; set `AUTO_INSTALL_DEPS = 0` if a test should stop and print the missing package list instead. `ROOT` is the separate switch for the external rootfs flow described below. Foreign-arch VM boots also rely on the static busybox builds under `tools/busybox/$ARCH/`, built explicitly with `bin/setup/build-busybox`.

For foreign-arch `ROOT` builds, the default is still a host-side cross-build. Set `BUILD_IN_ROOT = 1` if you want the kernel build and its dependency installation to happen inside the rootfs instead.

If you set `ARCH:=...` explicitly in a custom config or raw `ktest.pl` flow, the matching cross compiler must already be installed on the host or configured through `CROSS_COMPILE_*` in `setup.conf`.

For the default openSUSE cross toolchain prefixes, `./bin/setup/build-busybox` also installs the matching target libc development package needed by the static busybox builds. If a default toolchain is still incomplete, the busybox step skips that architecture with a warning instead of aborting the whole run. If you override `CROSS_COMPILE_*` in `setup.conf`, that custom toolchain is expected to already provide a usable sysroot with target headers such as `byteswap.h` plus static libc files such as `libc.a`.

Separate from the normal test flow, setup helpers have their own privilege requirements: `bin/setup/debootstrap` runs through `sudo`, and `./bin/setup/build-busybox` may also call `sudo zypper` when it needs to install the default openSUSE cross-toolchain packages.

## Project Layout

- `tests/`: top-level `ktest.pl` configs
- `include/`: reusable config fragments
- `hooks/`: scripts used by `PRE_*` and `POST_*` phases
- `bin/`: helper commands called by the generated `ktest.pl` config
- `bin/setup/`: setup-time helpers used by `setup.sh`
- `config/`: extra kernel config fragments
- `pkg/`: distro-specific dependency name mappings
- `tools/`: repo-local `virtme-ng`, busybox checkout plus static outputs, and a `ktest` symlink

Representative tests:

- `tests/vng`: the base build+boot flow
- `tests/nd_tbl`, `tests/ipv6_mod`: scenario-specific example test configs
- `tests/selftests/*`: sample wrappers around kernel selftests

## ktest Model

The important `ktest.pl` concepts for this tree are:

- `DEFAULTS`: shared settings
- `TEST_START`: one test stanza
- `INCLUDE`: include another config fragment from a `DEFAULTS` section
- `=`: set a `ktest.pl` option
- `:=`: set a config variable expanded while the file is parsed

That `=` versus `:=` split matters here:

- use `=` for normal `ktest.pl` options such as `TEST`, `TEST_TYPE`, `BUILD_TYPE`, `BUILD_IN_ROOT`, or `AUTO_INSTALL_DEPS`
- use `:=` for local composition variables such as `RUN_HOOK` or `PRE_*_CHAIN`
- if you override a parse-time variable from the command line, use `-D name:=value`

## Include Stack

Most VM-backed tests start with `include/defaults.conf`:

```text
include/defaults.conf
  -> include/base.conf
  -> include/patterns.conf
  -> include/rootfs.conf
  -> include/cross.conf
  -> include/vng.conf
  -> include/setenv.conf
```

Some tests use `include/suse.conf` instead:

```text
include/suse.conf
  -> include/base.conf
  -> include/patterns.conf
  -> include/rootfs.conf
  -> include/cross.conf
  -> include/vng.conf
  -> include/setenv.conf
```

Keep `include/setenv.conf` last if not using one of those entrypoints. It materializes the final command environment and hook commands.

What each layer does:

- `include/base.conf`: common environment and base hook chains
- `include/patterns.conf`: shared `TEST` helpers such as `DO_TEST_SIMPLE`
- `include/rootfs.conf`: default dependency setup, plus external root filesystem mount hooks when `ROOT` is set
- `include/cross.conf`: file-scoped arch resolution and cross-compiler defaults
- `include/vng.conf`: `virtme-ng` boot, SSH, reboot, machine naming, and VM-specific temp/output paths
- `include/setenv.conf`: exports the runtime environment and assembles the final `PRE_*` and `POST_*` hook commands
- `include/suse.conf`: alternate entrypoint used by a few SUSE-oriented tests

## Writing Tests

For a new VM-backed scenario, copy the nearest file in `tests/` and keep the shape simple:

1. `INCLUDE .../include/defaults.conf` or another top-level entrypoint such as `include/suse.conf`
2. Add `DEFAULTS OVERRIDE` for scenario-wide knobs
3. Add one or more `TEST_START` sections

Common knobs overridden in this tree:

- `ROOT`
- `ARCH`
- `VNG_PORT`
- `VNG_MEM`
- `VNG_ARGS`
- `BUILD_IN_ROOT`
- `SUSE_VERSION`
- `SUSE_PATCHLEVEL`
- `BUILD_TYPE`
- `ADD_CONFIG`
- `PREP_TEST`
- `POST_BUILD_APPEND`
- `AUTO_INSTALL_DEPS`
- `DEPS`

`ROOT`, `ARCH`, and `VNG_PORT` are file-scoped parse-time variables in this tree. Define them with `:=` before including `include/defaults.conf` or another top-level include such as `include/suse.conf`, and override them with `-D ROOT:=...`, `-D ARCH:=...`, or `-D VNG_PORT:=...` on the command line. `ARCH` accepts common aliases such as `riscv64` and `aarch64`, but k-lab normalizes them to the Linux/Kbuild names internally before invoking the build helpers. If `ROOT` expands `${ARCH}`, define `ARCH := ...` first. Do not set these variables inside `TEST_START`. In practice that means one effective `ROOT`, `ARCH`, and `VNG_PORT` per test file.

With `include/suse.conf`, `SUSE_VERSION` and `SUSE_PATCHLEVEL` are normal test options. Leave them unset for the default openSUSE Tumbleweed config bits, or set both with `=` in `DEFAULTS OVERRIDE` or a `TEST_START` to select an SLE kernel config.

`VNG_MEM` is a normal runtime option. It defaults to `1G` and is passed to `virtme-ng` as the VM memory size, so it can be overridden with `VNG_MEM = 2G` in a test or `-D VNG_MEM=2G` on the command line.

`VNG_ARGS` is also a normal runtime option. It is appended to the `virtme-ng` command line after k-lab's built-in defaults, so use it for extra guest arguments such as `--user root` or kernel append args, and only repeat things like memory, rootfs, or SSH flags when you intentionally want the later `virtme-ng` argument to win.

`BUILD_IN_ROOT` is a normal runtime option. Leave it at `0` for the default host build path, or set `BUILD_IN_ROOT = 1` to force the kernel build to run inside the rootfs. The main practical use is foreign-arch roots where you want to use the compiler toolchain from inside the rootfs instead of host cross-compilers. In that mode, k-lab still passes `ARCH`, but it stops passing the host `CROSS_COMPILE` prefix so the rootfs can use its own native toolchain. On older distros with multiple compiler slots, package installation alone may not switch the default `/usr/bin/gcc`; those roots still need their preferred compiler configured explicitly.

`DEPS` adds test-specific packages on top of k-lab's built-in base tool list, so tests only need to name the extra packages they care about. Dependency names are resolved through distro-specific maps under `pkg/`, for example `pkg/debian`, `pkg/tumbleweed`, and `pkg/sles12`. Those maps are mainly for package renames across distros. If a dependency is not mapped, `bin/install` falls back to using the literal package name and prints a warning once for that dependency. `AUTO_INSTALL_DEPS` now defaults to `1`; set it to `0` in a test or on the command line when you want missing packages to stay a hard failure.

Hook rule of thumb:

- use the shared chains in `include/*.conf` for framework ordering
- use `*_APPEND` in `tests/*` for scenario-local work
- replace `PRE_*` or `POST_*` directly only when you want to own the whole phase

Hooks are assembled in two layers:

- `PRE_*_CHAIN` and `POST_*_CHAIN` in `include/*.conf` build the shared phase order
- `*_APPEND` in `tests/*` adds scenario-local commands at the end of that phase

The final `PRE_*` and `POST_*` commands are materialized in `include/setenv.conf` and run left-to-right with `&&`.

Small example:

- the default `POST_BUILD` chain always runs `hooks/post_build`, which calls the kernel's `scripts/clang-tools/gen_compile_commands.py` helper to generate `compile_commands-$ARCH.json` in the kernel tree and repoints `compile_commands.json` at it
- a test can then extend that phase with `POST_BUILD_APPEND`; for example, the selftests configs append hooks that install the selftest binaries after the default post-build work has finished

Pattern helpers from `include/patterns.conf`:

- `DO_TEST_SIMPLE`: pass or fail on `TEST_BIN`'s exit status
- `DO_TEST_PATTERN_OK`: pass only if `PATTERN` is found in the captured output
- `DO_TEST_PATTERN_FAIL`: pass only if `PATTERN` is not found in the captured output

Two caveats:

- `DO_TEST_PATTERN_*` key off log text, not the command exit status
- if `PREP_TEST` is set, it is inserted before `TEST_BIN` in the same shell command, so it must end with `&&` or `;`

## External Root Filesystems and Privileges

There are two privileged runtime paths in the normal test flow: automatic dependency installation and `ROOT`. By default, missing packages from the effective install list are installed automatically; with `ROOT` unset that means the host package manager. Set `AUTO_INSTALL_DEPS = 0` if you want missing packages to stop the run instead. If `ROOT` is set, build and test commands inside the rootfs run through a host-root `chroot`. `ROOT` is expected to point at a rootfs tree that is readable and writable by your user; rootfs command execution uses `sudo -n chroot`, so package managers and other tools inside the rootfs see normal root ownership semantics.

When `ROOT` points at a foreign-arch userspace, `include/cross.conf` resolves the matching file-scoped `ARCH` automatically from a binary inside the rootfs. By default, kernel builds then stay on the host with the resolved `ARCH` and `CROSS_COMPILE`, while `virtme-ng` gets the matching guest arch plus a static busybox built with `bin/setup/build-busybox`. Set `BUILD_IN_ROOT = 1` if you want that foreign-root build to happen inside the rootfs instead. In that mode, and for any other host-side command execution inside a foreign `ROOT`, the host still needs passwordless `sudo` plus `binfmt_misc` registration with QEMU user-mode emulation.

Host-root escalation is centralized in `bin/run`, which invokes host-side privileged commands through `sudo -n`. There is no interactive fallback: any flow that reaches this path requires passwordless `sudo`, and `ktest.pl` is not set up to handle a password prompt mid-run. In practice that means installing `DEPS` on the host when `ROOT` is unset, plus the rootfs mount or umount helpers used by `ROOT`-backed test flows. Test configs in `tests/` and shared fragments in `include/` should therefore be treated as trusted local code.

For the built-in flows, the expected sudoers allowlist is:

- `/usr/bin/chroot`
- `/usr/bin/mount`
- `/usr/bin/umount`
- `/usr/bin/apt` on Debian or Ubuntu systems
- `/usr/bin/zypper` on SUSE or openSUSE systems

## Root Filesystem Creation

`k-lab` only consumes an existing rootfs tree (assumed to be owned by the calling uid); it does not try to prescribe how you create it. Practical options include:

- `bin/setup/debootstrap -r /roots/debian/sid/x86_64` as a small wrapper around the upstream `debootstrap` tool for quick Debian rootfs bootstraps from this repo
- `virtme-ng` via its `--root` creates from Ubuntu cloud images when the target directory does not exist
- `alpine-make-rootfs`: <https://github.com/alpinelinux/alpine-make-rootfs>

For foreign-arch roots used by host-side rootfs commands, make sure the host also has the relevant `binfmt_misc` and QEMU user-mode support installed.
