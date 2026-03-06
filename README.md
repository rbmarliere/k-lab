# k-lab

`k-lab` is a small layer on top of `ktest.pl` for local kernel build, boot, and test loops using `virtme-ng`.

`ktest.pl` is good at describing repeatable build, install, boot, and test flows with reusable config fragments and per-test overrides, while `virtme-ng` is good at booting a locally built kernel quickly in QEMU. The whole point of this tree is to mix those two together: keep `ktest.pl` as the control plane and use `virtme-ng` as the fast local VM backend. It also gives you a straightforward way to build and run tests against an external root filesystem instead of the host.

This repo does not replace `ktest.pl`. It gives you:

- shared config fragments under `include/`
- shell helpers under `bin/` and `hooks/`
- a small `kt` wrapper plus Bash completion in `kt.completion`
- ready-to-edit test configs under `tests/`

It has only been tested on an openSUSE Tumbleweed host so far. It is still a bit scrappy and very much a work in progress, so treat it as just a handy starting point for your own local `ktest.pl` setup.

For raw `ktest.pl` syntax and behavior, start with:

- [sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf)
- [examples/README](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples/README)

## Quick Start

`setup.conf` is the machine-local file for this checkout. It only needs:

- `LINUX_GIT`
- `THIS_DIR`

`VNG_DIR` is always `${THIS_DIR}/virtme-ng`.

`setup.sh` clones `virtme-ng` into that path if it is missing and builds it locally - it's possible to use a symlink instead, for example.

This project is Bash-first: the wrapper and helper scripts assume Bash, and `kt` itself is defined when you source `kt.completion`.

Bootstrap:

1. Edit `setup.conf`.
2. Run `./setup.sh`.
3. Source the wrapper:

   ```bash
   source /path/to/kt.completion
   ```

   This is the main entrypoint for interactive use, not an optional extra.

4. Run `kt` from inside a Linux kernel worktree.

Examples:

```bash
kt build
kt -D ROOT:=/roots/debian/sid/x86_64 build
kt vng
kt -n selftests/net
kt -D VNG_PORT:=22999 nd_tbl
```

Wrapper options:

- `-B` sets `BUILD_TYPE=nobuild`
- `-C` sets `BUILD_NOCLEAN=1`
- `-D name=value` passes a `ktest.pl` override
- `-D name:=value` overrides a parse-time config variable
- `-n` prints the resolved config and exits

The wrapper also does its own `ktest.pl --dry-run` before a real run, preflights resolved `ROOT` values for the userns flow, flags runs that are configured to use `ROOT` or auto-install `DEPS`, asks for confirmation before continuing with them, asks again before reusing a `TMP_DIR` that already contains `kt.log`, and creates `TMP_DIR.lock` so two runs do not stomp the same output directory.

## Dependencies

`k-lab` itself only checks a few basics:

- `LINUX_GIT` must point at a real kernel git worktree, preferably master and unrelated to the worktree being targeted for testing
- `${LINUX_GIT}/tools/testing/ktest/ktest.pl` must exist
- after `./setup.sh`, `${THIS_DIR}/virtme-ng/vng` must exist

In practice, the host should also have:

- `bash`, `git`, `make`, `python3`
- `cargo` and `rustc` for the local `virtme-ng` build
- Python `argcomplete` and `requests` for `virtme-ng`
- QEMU (`qemu-system-*` or `qemu-kvm`), with KVM if you want decent performance
- `unshare` from `util-linux`, plus working subordinate uid and gid mappings for `--map-auto`, for `ROOT`-backed runs
- `ssh` and `ssh-keygen` on the host, plus `sshd` in the guest or rootfs if you use the SSH flow

Per-test extras live in `DEPS`. Missing packages are only auto-installed when a test sets `AUTO_INSTALL_DEPS = 1`; otherwise the run stops and prints the missing package list. `ROOT` is the separate switch for the external rootfs flow described below.

## Project Layout

- `tests/`: top-level `ktest.pl` configs
- `include/`: reusable config fragments
- `hooks/`: scripts used by `PRE_*` and `POST_*` phases
- `bin/`: helper commands called by the generated `ktest.pl` config
- `config/`: extra kernel config fragments
- `pkg/`: dependency name mappings for Debian and SUSE

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
  -> include/vng.conf
  -> include/setenv.conf
```

Keep `include/setenv.conf` last if not using `include/defaults.conf`. It materializes the final command environment and hook commands.

What each layer does:

- `include/base.conf`: common paths, logs, temp dirs, and base hook chains
- `include/patterns.conf`: shared `TEST` helpers such as `DO_TEST_SIMPLE`
- `include/rootfs.conf`: default dependency setup, plus external root filesystem mount hooks when `ROOT` is set
- `include/vng.conf`: `virtme-ng` boot, SSH, reboot, and VM-specific defaults
- `include/setenv.conf`: exports the runtime environment and assembles the final `PRE_*` and `POST_*` hook commands
- `include/suse.conf`: optional SUSE-specific setup

`tests/build` is the main exception: it skips `include/vng.conf` because it is build-only. You may use `ROOT` to target building within it, though.

## Writing Tests

For a new VM-backed scenario, copy the nearest file in `tests/` and keep the shape simple:

1. `INCLUDE ../include/defaults.conf`
2. Add `DEFAULTS OVERRIDE` for scenario-wide knobs
3. Add one or more `TEST_START` sections

Common knobs overridden in this tree:

- `ROOT`
- `VNG_PORT`
- `VNG_ARGS`
- `BUILD_TYPE`
- `ADD_CONFIG`
- `PREP_TEST`
- `POST_BUILD_APPEND`
- `AUTO_INSTALL_DEPS`
- `DEPS` and `INSTALL_DEPS`

Dependency names in `DEPS` are abstract keys resolved through `pkg/debian` and `pkg/suse`. If you extend `DEPS` in a test, also republish it with `INSTALL_DEPS = ${DEPS}` in the same override block. Set `AUTO_INSTALL_DEPS = 1` only for tests that should install missing packages automatically.

Hook rule of thumb:

- use the shared chains in `include/*.conf` for framework ordering
- use `*_APPEND` in `tests/*` for scenario-local work
- replace `PRE_*` or `POST_*` directly only when you want to own the whole phase

Hooks are assembled in two layers:

- `PRE_*_CHAIN` and `POST_*_CHAIN` in `include/*.conf` build the shared phase order
- `*_APPEND` in `tests/*` adds scenario-local commands at the end of that phase

The final `PRE_*` and `POST_*` commands are materialized in `include/setenv.conf` and run left-to-right with `&&`.

Small example:

- the default `POST_BUILD` chain always runs `hooks/post_build`, which calls the kernel's `scripts/clang-tools/gen_compile_commands.py` helper and generates a `compile_commands.json` database from the build output
- a test can then extend that phase with `POST_BUILD_APPEND`; for example, the selftests configs append hooks that install the selftest binaries after the default post-build work has finished

Pattern helpers from `include/patterns.conf`:

- `DO_TEST_SIMPLE`: pass or fail on `TEST_BIN`'s exit status
- `DO_TEST_PATTERN_OK`: pass only if `PATTERN` is found in the captured output
- `DO_TEST_PATTERN_FAIL`: pass only if `PATTERN` is not found in the captured output

Two caveats:

- `DO_TEST_PATTERN_*` key off log text, not the command exit status
- if `PREP_TEST` is set, it is inserted before `TEST_BIN` in the same shell command, so it must end with `&&` or `;`

## External Root Filesystems and Privileges

There are two explicit privilege switches in this tree: `AUTO_INSTALL_DEPS = 1` and `ROOT`. If `AUTO_INSTALL_DEPS = 1`, missing `DEPS` are installed automatically; with `ROOT` unset that means the host package manager, and with `ROOT` set that same install path runs inside the rootfs through the namespace-root helper. If `ROOT` is set, the rootfs helpers also mount the external rootfs, bind in `BUILD_DIR` and `OUTPUT_DIR`, and run the build or test commands inside it. `ROOT` is expected to point at a rootfs tree that is readable and writable by your user; rootfs command execution uses `unshare --map-root-user --map-auto --mount`, so commands run as root inside the rootfs while writes still map back to your host uid outside.

Host-root escalation is centralized in `bin/run`, which invokes host-side privileged commands through `sudo -n`. There is no interactive fallback: any flow that reaches this path requires passwordless `sudo`, and `ktest.pl` is not set up to handle a password prompt mid-run. In practice that means installing `DEPS` on the host when `ROOT` is unset, plus the rootfs mount or umount helpers used by `ROOT`-backed test flows. Test configs in `tests/` and shared fragments in `include/` should therefore be treated as trusted local code.

For the built-in flows, the expected sudoers allowlist is:

- `/usr/bin/mount`
- `/usr/bin/umount`
- `/usr/bin/apt` on Debian or Ubuntu systems
- `/usr/bin/zypper` on SUSE or openSUSE systems

## TODO

- Multi-arch (with static busybox) setup
