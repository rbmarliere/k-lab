# k-lab

`k-lab` is a small layer on top of `ktest.pl` for local kernel build, boot, and test loops using `virtme-ng`.

`ktest.pl` is good at describing repeatable build, install, boot, and test flows with reusable config fragments and per-test overrides, while `virtme-ng` is good at booting a locally built kernel quickly in QEMU. The whole point of this tree is to mix those two together: keep `ktest.pl` as the control plane and use `virtme-ng` as the fast local VM backend. It also gives you a straightforward way to build and run tests against an external root filesystem instead of the host.

This repo does not replace `ktest.pl`. It gives you:

- shared config fragments under `include/`
- shell helpers under `bin/` and `hooks/`
- setup helpers under `bin/setup/`
- a small `kt` wrapper plus Bash completion in `kt.completion`
- ready-to-edit test configs under `tests/`
- local tool state under `tools/`

It has only been tested on an openSUSE Tumbleweed host so far. It is still a bit scrappy and very much a work in progress, so treat it as just a handy starting point for your own local `ktest.pl` setup.

For raw `ktest.pl` syntax and behavior, start with:

- [sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf)
- [examples/README](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples/README)

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

This project is Bash-first: the wrapper and helper scripts assume Bash, and `kt` itself is defined when you source `kt.completion`.

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh`.
3. If you plan to boot a foreign-arch `ROOT`, build the matching static busybox binary:

   ```bash
   ./bin/setup/build-busybox arm64
   ```

   With no arguments it builds all supported foreign arches.

4. Source the wrapper:

   ```bash
   source /path/to/kt.completion
   ```

   This is the main entrypoint for interactive use, not an optional extra.

4. Run `kt` from inside a Linux kernel worktree.

Examples:

```bash
kt build
kt vng
kt -D ROOT:=/roots/debian/sid/x86_64 build
kt -D ROOT:=/roots/suse/Tumbleweed/vm-aarch64 build
kt -D ROOT:=/roots/suse/Tumbleweed/vm-aarch64 -D BUILD_IN_ROOT=1 build
kt -D ROOT:=/roots/suse/Tumbleweed/vm-aarch64 vng
kt -n selftests/net
kt -n -D ROOT:=/roots/suse/Tumbleweed/vm-aarch64 vng
kt -D VNG_PORT:=22999 nd_tbl
```

Wrapper options:

- `-B` sets `BUILD_TYPE=nobuild`
- `-C` sets `BUILD_NOCLEAN=1`
- `-D name=value` passes a `ktest.pl` option override
- `-D name:=value` overrides a file-scoped parse-time variable such as `ROOT`, `ARCH`, or `VNG_PORT`
- `-n` prints the resolved config and exits

The wrapper also does its own `ktest.pl --dry-run` before a real run, preflights resolved `ROOT` values for the host-root execution path, checks foreign-root execution support for the host, flags runs that are configured to use `ROOT` or auto-install `DEPS`, asks for confirmation before continuing with them, asks again before reusing a `TMP_DIR` that already contains `kt.log`, and creates `TMP_DIR.lock` so two runs do not stomp the same output directory.

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

Per-test extras live in `DEPS`. Missing packages are only auto-installed when a test sets `AUTO_INSTALL_DEPS = 1`; otherwise the run stops and prints the missing package list. `ROOT` is the separate switch for the external rootfs flow described below. Foreign-arch VM boots also rely on the static busybox builds under `tools/busybox/$ARCH/`, built explicitly with `bin/setup/build-busybox`.

For foreign-arch `ROOT` builds, the default is still a host-side cross-build. Set `BUILD_IN_ROOT = 1` if you want the kernel build and its dependency installation to happen inside the rootfs instead.

For the default openSUSE cross toolchain prefixes, `./bin/setup/build-busybox` also installs the matching target libc development package needed by the static busybox builds. If a default toolchain is still incomplete, the busybox step skips that architecture with a warning instead of aborting the whole run. If you override `CROSS_COMPILE_*` in `setup.conf`, that custom toolchain is expected to already provide a usable sysroot with target headers such as `byteswap.h` plus static libc files such as `libc.a`.

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

- `tests/build`: build-only flow
- `tests/vng`: boot a `virtme-ng` guest and keep it running
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

- use `=` for normal `ktest.pl` options such as `TEST`, `TEST_TYPE`, or `BUILD_TYPE`
- use `:=` for local composition variables such as `DEPS`, `RUN_HOOK`, or `PRE_*_CHAIN`
- if you override a parse-time variable from the command line, use `-D name:=value`

## Include Stack

Most VM-backed tests start with:

```text
include/defaults.conf
  -> include/base.conf
  -> include/patterns.conf
  -> include/rootfs.conf
  -> include/cross.conf
  -> include/vng.conf
  -> include/setenv.conf
```

Keep `include/setenv.conf` last if not using `include/defaults.conf`. It materializes the final command environment and hook commands.

What each layer does:

- `include/base.conf`: common environment and base hook chains
- `include/patterns.conf`: shared `TEST` helpers such as `DO_TEST_SIMPLE`
- `include/rootfs.conf`: default dependency setup, plus external root filesystem mount hooks when `ROOT` is set
- `include/cross.conf`: file-scoped arch resolution and cross-compiler defaults
- `include/vng.conf`: `virtme-ng` boot, SSH, reboot, machine naming, and VM-specific temp/output paths
- `include/setenv.conf`: exports the runtime environment and assembles the final `PRE_*` and `POST_*` hook commands
- `include/suse.conf`: optional SUSE-specific setup

`tests/build` is the main exception: it skips `include/vng.conf`, pulls in `include/paths.conf` directly, and stays build-only. It still includes `include/cross.conf`, so it may cross-build for a foreign `ROOT` without using `virtme-ng`.

## Writing Tests

For a new VM-backed scenario, copy the nearest file in `tests/` and keep the shape simple:

1. `INCLUDE ../include/defaults.conf`
2. Add `DEFAULTS OVERRIDE` for scenario-wide knobs
3. Add one or more `TEST_START` sections

Common knobs overridden in this tree:

- `ROOT`
- `ARCH`
- `VNG_PORT`
- `BUILD_IN_ROOT`
- `VNG_ARGS`
- `BUILD_TYPE`
- `ADD_CONFIG`
- `PREP_TEST`
- `POST_BUILD_APPEND`
- `AUTO_INSTALL_DEPS`
- `DEPS` and `INSTALL_DEPS`

`ROOT`, `ARCH`, and `VNG_PORT` are file-scoped parse-time variables in this tree. Set them with `:=` in the file-wide defaults area and override them with `-D ROOT:=...`, `-D ARCH:=...`, or `-D VNG_PORT:=...` on the command line. Do not set them inside `TEST_START`. In practice that means one effective `ROOT`, `ARCH`, and `VNG_PORT` per test file.

`BUILD_IN_ROOT` is a normal runtime option. Leave it at `0` for the default host build path, or set `BUILD_IN_ROOT = 1` to force the kernel build to run inside the rootfs. The main practical use is foreign-arch roots where you want to use the compiler toolchain from inside the rootfs instead of host cross-compilers. In that mode, k-lab still passes `ARCH`, but it stops passing the host `CROSS_COMPILE` prefix so the rootfs can use its own native toolchain. On older distros with multiple compiler slots, package installation alone may not switch the default `/usr/bin/gcc`; those roots still need their preferred compiler configured explicitly.

Dependency names in `DEPS` are abstract keys resolved through distro-specific maps under `pkg/`, for example `pkg/debian`, `pkg/tumbleweed`, and `pkg/sles12`. Those maps may be intentionally partial; a missing abstract dependency means that flow is not supported for that distro map yet. If you extend `DEPS` in a test, also republish it with `INSTALL_DEPS = ${DEPS}` in the same override block. Set `AUTO_INSTALL_DEPS = 1` only for tests that should install missing packages automatically.

Hook rule of thumb:

- use the shared chains in `include/*.conf` for framework ordering
- use `*_APPEND` in `tests/*` for scenario-local work
- replace `PRE_*` or `POST_*` directly only when you want to own the whole phase

Hooks are assembled in two layers:

- `PRE_*_CHAIN` and `POST_*_CHAIN` in `include/*.conf` build the shared phase order
- `*_APPEND` in `tests/*` adds scenario-local commands at the end of that phase

The final `PRE_*` and `POST_*` commands are materialized in `include/setenv.conf` and run left-to-right with `&&`.

Small example:

- the default `POST_BUILD` chain always runs `hooks/post_build`, which calls the kernel's `scripts/clang-tools/gen_compile_commands.py` helper to generate `compile_commands.json.$ARCH` in the kernel tree and repoints `compile_commands.json` at it
- a test can then extend that phase with `POST_BUILD_APPEND`; for example, the selftests configs append hooks that install the selftest binaries after the default post-build work has finished

Pattern helpers from `include/patterns.conf`:

- `DO_TEST_SIMPLE`: pass or fail on `TEST_BIN`'s exit status
- `DO_TEST_PATTERN_OK`: pass only if `PATTERN` is found in the captured output
- `DO_TEST_PATTERN_FAIL`: pass only if `PATTERN` is not found in the captured output

Two caveats:

- `DO_TEST_PATTERN_*` key off log text, not the command exit status
- if `PREP_TEST` is set, it is inserted before `TEST_BIN` in the same shell command, so it must end with `&&` or `;`

## External Root Filesystems and Privileges

There are two explicit privilege switches in this tree: `AUTO_INSTALL_DEPS = 1` and `ROOT`. If `AUTO_INSTALL_DEPS = 1`, missing `DEPS` are installed automatically; with `ROOT` unset that means the host package manager. If `ROOT` is set, build and test commands inside the rootfs run through a host-root `chroot`. `ROOT` is expected to point at a rootfs tree that is readable and writable by your user; rootfs command execution uses `sudo -n chroot`, so package managers and other tools inside the rootfs see normal root ownership semantics.

When `ROOT` points at a foreign-arch userspace, `include/cross.conf` resolves the matching file-scoped `ARCH` automatically from a binary inside the rootfs. By default, kernel builds then stay on the host with the resolved `ARCH` and `CROSS_COMPILE`, while `virtme-ng` gets the matching guest arch plus a static busybox built with `bin/setup/build-busybox`. Set `BUILD_IN_ROOT = 1` if you want that foreign-root build to happen inside the rootfs instead. In that mode, and for any other host-side command execution inside a foreign `ROOT`, the host still needs passwordless `sudo` plus `binfmt_misc` registration with QEMU user-mode emulation.

Host-root escalation is centralized in `bin/run`, which invokes host-side privileged commands through `sudo -n`. There is no interactive fallback: any flow that reaches this path requires passwordless `sudo`, and `ktest.pl` is not set up to handle a password prompt mid-run. In practice that means installing `DEPS` on the host when `ROOT` is unset, plus the rootfs mount or umount helpers used by `ROOT`-backed test flows. Test configs in `tests/` and shared fragments in `include/` should therefore be treated as trusted local code.

For the built-in flows, the expected sudoers allowlist is:

- `/usr/bin/chroot`
- `/usr/bin/mount`
- `/usr/bin/umount`
- `/usr/bin/apt` on Debian or Ubuntu systems
- `/usr/bin/zypper` on SUSE or openSUSE systems

## Rootfs Creation

`k-lab` only consumes an existing rootfs tree; it does not try to prescribe how you create it. Practical options include:

- `bin/setup/debootstrap -r /roots/debian/sid/x86_64` for a quick Debian rootfs bootstrap from this repo
- `debootstrap` for Debian or Ubuntu roots
- distro-native bootstrap tools such as `dnf --installroot`, `zypper --root`, or container/rootfs export workflows
- `virtme-ng` rootfs creation via its `--root` support and Ubuntu cloud images, if that fits your workflow

For foreign-arch roots used by host-side rootfs commands, make sure the host also has the relevant `binfmt_misc` and QEMU user-mode support installed.
