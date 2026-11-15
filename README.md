# k-lab

Kernel build/boot/test loops with `ktest.pl` and `virtme-ng`. ktest handles
builds, monitoring, iteration, bisect and patchcheck; vng boots the kernel
against a disk image with `--root-disk`.

## Setup

Optionally edit `setup.conf`: `SUSE_KERNEL_SOURCE_GIT` supplies SUSE configs,
and `LTP_GIT` supplies LTP. `kt` determines its checkout path (`THIS_DIR`)
automatically. Then:

```bash
./setup.sh
source /path/to/k-lab/k-lab.sh
```

Setup downloads the latest upstream `ktest.pl` and `config-bisect.pl` into
`tools/ktest/` on every run and clones missing virtme-ng and busybox-builder
checkouts. It does not install packages or provision root filesystems.
Existing local checkouts can be symlinked into `tools/` instead.

Provide a static busybox for every guest architecture. On openSUSE, the
external builder can prepare dependencies and build it:

```bash
cd tools/busybox-static-builder
./prepare x86_64   # may install packages with sudo/zypper
./build x86_64
```

Set `BUSYBOX = /path/to/static/busybox` in `setup.conf` or a test config to
use another binary. Paths can use `${KLAB_ARCH}` (for example `arm64` or
`x86_64`) to select a binary per architecture.
Set `VNG = /path/to/vng` there to select a different executable.
Install the build tools and vng dependencies yourself; see the
[vng documentation](https://github.com/arighi/virtme-ng#readme).

## Tests

Write a separate test under `tests/` for each task. Keep its ktest config,
fragments, and reproducer files together. Keep run settings in that file and
its includes: architecture, disk and rootfs paths, toolchain, resources,
target selection and iteration counts. Use separate config files for variants.
Do not use shell environment assignments to configure a launch.

Always declare `ARCH` before the first `INCLUDE`, including native builds.
For example, `tests/my-test/test`:

```conf
ARCH := x86_64
INCLUDE ${THIS_DIR}/include/defaults.conf

DEFAULTS OVERRIDE
ROOT_DISK = /path/to/x86_64.img
POST_BUILD_APPEND = cp ${THIS_DIR}/tests/my-test/run.sh ${OUTPUT_DIR}/run.sh

TEST_START
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh
```

Put verdict logic in `run.sh` and return a meaningful exit status. For a
build-only check, use `TEST_TYPE = build`; no image or guest script is needed.
Extend phase hooks with their corresponding `*_APPEND` options.

Include `include/suse.conf` after defaults for SUSE product configuration. Set
`SUSE_BRANCH = stable` or the relevant config-tree directory. `SUSE_FLAVOR`
selects the config filename and defaults to `default`. Leave `SUSE_VERSION` and
`SUSE_PATCHLEVEL` unset for Tumbleweed, or set both for SLE.

The SUSE include supplies the flavor through `ADD_CONFIG`. To add test-specific
fragments without replacing it, retain the inherited list after `TEST_START`:

```conf
TEST_START
TEST_TYPE = build
ADD_CONFIG = ${ADD_CONFIG} ${THIS_DIR}/tests/my-test/extra.config
```

A plain per-test `ADD_CONFIG = ...` replaces the flavor fragment. This
self-reference retains it only in a test section; do not use it to redefine
`ADD_CONFIG` in `DEFAULTS OVERRIDE`. Later fragments override earlier ones;
`MIN_CONFIG` takes precedence over all `ADD_CONFIG` fragments.

For full syntax, see ktest's [sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf) and
[examples](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples/README).

## Run

Run from the kernel worktree, selecting your task's test:

```bash
kt -n my-test    # resolved options only
kt my-test       # build and run the configured test
kt -C my-test    # rebuild without cleaning
```

`compile_commands.json` is generated in `OUTPUT_DIR` by default and linked
from the kernel source directory (`BUILD_DIR`). The latest build selects the
active database. Set `COMPILE_COMMANDS = 0` in the test config to disable
generation and leave any existing link unchanged.

Select a test by its name under `tests/`, a config path, or a directory
containing a `test` file. Command-line flags control execution and provide
advanced overrides:

- `-C` sets `BUILD_NOCLEAN=1`; `-n` prints resolved options; `-y` disconnects
  stdin.
- `-b` runs in the background, implies `-y`, and captures stdout/stderr in
  `TMP_DIR/ktlog`.
- `-D` passes option overrides to ktest.

Background runs support immediate status checks and bounded waits:

```bash
kt -b my-test
kt status my-test
kt wait my-test
```

`status` reports immediately; `wait` waits up to 300 seconds by default (`-t`
changes this). Both resolve `[test]` exactly like a run. Run them from the
same kernel worktree with the same config file used for launch. Keep that
config unchanged until the run finishes.

Completed runs save `exit=<code>` in `TMP_DIR/status`. Both commands return
that exit code and print log paths and the last 40 lines of any
`testlog-*` files. These are runner exit codes, not independent kernel
verdicts. Logs are ktest-managed and may remain from an earlier run if the
current run never reached that phase. While running, `status` returns 0; `wait`
returns 124 on timeout, without stopping the run. Runs interrupted before
cleanup (for example, SIGKILL) have no completed exit status.

Set `ARCH := ...` before the first `INCLUDE` in each test config. Supported
kernel architecture names are `x86_64`, `arm64`, `arm`, `powerpc`, `s390`, and
`riscv`. Disk names and chroot contents do not select it. Foreign host builds
use SUSE compiler prefixes by default; set `CROSS_COMPILE = ...` in the config
if a different prefix is needed.

`CC`, `HOSTCC`, and `HOSTCFLAGS` apply to every `MAKE_CMD` invocation. Empty
values leave the makefile defaults in effect; nonempty values are passed as make
arguments. Chroot builds ignore the configured `CROSS_COMPILE` prefix.

Use ktest's `MAKE_CMD` for other persistent make settings:

```conf
DEFAULTS OVERRIDE
MAKE_CMD = ${RUN} ${THIS_DIR}/bin/make LLVM=1 LD=ld.lld KCFLAGS="-O1 -g"
```

Kernel make hooks should also invoke `${MAKE_CMD}` to use the same settings and
architecture/chroot handling. The shell parses the command once; `bin/make`
forwards its arguments unchanged. Compiler selections must resolve inside the
chroot when using chroot builds.

`BUILD_OPTIONS` supplies extra arguments only for the kernel build, such as
parallelism or additional targets. It does not apply to configuration or other
make invocations and is not exported to hooks.

`kt` manages `TMP_DIR`, choosing `tmp/<worktree>-<config>` under the k-lab
checkout and protecting it with `flock`. Do not set `TMP_DIR` in the test
config; `kt -n` shows the resolved path. Concurrent runs need separate config
files, workspaces, output directories and `VNG_PORT` values. The default SSH
port is 22000; there is no automatic port allocation.

Tests can share a kernel build by setting the same `OUTPUT_DIR`, while each
keeps its own `TMP_DIR` for logs and status. `kt` also locks `OUTPUT_DIR`, so
only one run uses a build at a time. Keep the shared settings in a build
profile under `profiles/`, named after what it builds. Profiles are local,
like most tests; `profiles/Tumbleweed-x86_64.conf` is the tracked example.

- Everything that affects the kernel build (branch, version, config
  fragments, toolchain) belongs in the profile. Tests that differ here
  rebuild each other's objects.
- `BUILD_NOCLEAN = 1` keeps runs from wiping the build. Delete `OUTPUT_DIR`
  to force a clean build; do so after changing the toolchain, since stale
  tools are not rebuilt.
- Build one source tree per `OUTPUT_DIR`.

A test includes the profile after `defaults.conf` and sets only its own
resources and guest script:

```conf
ARCH := x86_64
INCLUDE ${THIS_DIR}/include/defaults.conf
INCLUDE ${THIS_DIR}/profiles/Tumbleweed-x86_64.conf

DEFAULTS OVERRIDE
POST_BUILD_APPEND = cp ${THIS_DIR}/tests/my-test/run.sh ${OUTPUT_DIR}/run.sh

TEST_START
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh
```

## Logs and artifacts

`TMP_DIR` contains the following logs:

- `buildlog-*`: compiler and build output.
- `dmesg-*`: captured guest console/kernel output.
- `ktestlog`: ktest's phase decisions and combined output.
- `ktlog`: background runner stdout/stderr, including launch errors.
- `testlog-*`: test command output and assertions.
- `vnglog`: VM launch and boot output.

With the default storage settings, ktest saves available logs and the kernel
config under `failures/<run>/` or `successes/<run>/`. These copies are named
`testlog`, `buildlog`, `dmesg`, `logfile`, and `config`. Ktest reports the
archive path with `Saved info to`. Logs may be absent or retained from an
earlier run if the current run never reached their phase.

VM launches also record `cmdline-vng` and `cmdline-qemu`, described below.

## VM policy

Boots require `ROOT_DISK`, a raw or qcow2 image. vng handles the boot
parameters and module exposure. The minimum kernel fragment comes from `vng
--kconfig --dry-run`.

The guest root is writable, but QEMU's `-snapshot` discards disk changes when
the VM stops. No persistent disk overlays are managed by k-lab. Set
`VNG_QEMU_OPTS =` to disable snapshots and modify the base images directly.
This also affects extra disks; do not share images between writable guests
without snapshots.

Guest paths:

- `/mnt/src`: kernel source, read-only
- `/mnt/build`: build output, writable; also the SSH working directory

Only files written to exported output directories survive a VM stop. Set
`VNG_ROOT_DEV` (default `/dev/vda`) and `VNG_ROOT_FSTYPE` (default `ext4`) for
other image layouts; enable the chosen filesystem in the kernel config.
`VNG_MEM` defaults to `1G`; `VNG_ARGS` forwards other vng flags, such as
`--cpus 4 --systemd`.

Ctrl-C stops the run and its VM. For interactive SSH, use the run's
`TMP_DIR/ssh` helper, which already contains the workspace and port. Do not
assemble another command with separate configuration values.

Each VM launch records the shell-quoted vng invocation in `TMP_DIR/cmdline-vng`
and a QEMU command preview in `TMP_DIR/cmdline-qemu`. Both include the
wrapper's defaults and the run's options. A failed preview prevents launch.
Temporary socket and file-descriptor paths in the preview differ from the
actual launch.

`kt -n <test>` prints configured RAM, CPUs (`VNG_ARGS`), disk, architecture,
and snapshot settings without launching a VM.

`bin/kt-kill <TMP_DIR>` requests graceful cancellation of the whole run.

## Chroot builds

Set `CHROOT_KERNEL = /path/to/rootfs` to run `MAKE_CMD` commands in that
rootfs, including configuration, kernel builds and headers. Leave
it empty to build on the host.

Commands run in unprivileged user/mount/PID namespaces with a writable
overlay. `TMP_DIR/chroot/` retains changes, one overlay per rootfs path;
mounts vanish when the command exits. The rootfs is not modified. Source and
output are bound in at their host paths, and builds use the chroot's native
toolchain, not `CROSS_COMPILE`. `bin/chroot` also binds the space-separated
paths in its `CHROOT_BINDS` environment variable.

`CHROOT_USER` selects a rootfs for standalone guest programs and defaults to
`CHROOT_KERNEL`. Build them with `${RUN_USER}`; kernel compiler settings do
not apply. Use a rootfs matching the guest's libraries, or leave it empty to
build on the host:

```conf
DEFAULTS OVERRIDE
CHROOT_USER = /path/to/guest/rootfs
POST_BUILD_APPEND = cp ${THIS_DIR}/tests/my-test/repro.c ${OUTPUT_DIR}/ && ${RUN_USER} gcc -o ${OUTPUT_DIR}/repro ${OUTPUT_DIR}/repro.c
```

Kernel builds use `CHROOT_KERNEL`. Complete selftest collections, including
their test modules, build in `CHROOT_USER`.

The whole rootfs must be owned by the invoking user and contain the build
dependencies. Fix ownership with `sudo chown -R "$USER": /path/to/rootfs`.

Chroot builds need unprivileged user namespaces, OverlayFS, and util-linux
with `--forward-signals`. Foreign roots also need host qemu-user/binfmt
registration.

## Selftests

Include `include/selftests.conf`, set `SELFTEST_TARGETS`, and add
`${BUILD_SELFTESTS}` to `POST_BUILD_APPEND`:

```conf
DEFAULTS OVERRIDE
CHROOT_KERNEL =
CHROOT_USER = /path/to/guest/rootfs
SELFTEST_TARGETS = fchmodat2
POST_BUILD_APPEND = ${BUILD_SELFTESTS}
```

Headers are generated through `MAKE_CMD`; the selected collections build
in `CHROOT_USER`, including their test modules. `O` and `KDIR` point at the
prepared kernel output. Build output uses kselftest's default,
`OUTPUT_DIR/kselftest`; module output follows each collection's rules.
Installed tests remain at `/mnt/build/kselftest/kselftest_install`. The
build root needs the collection's dependencies, including `make`, a compiler
and `rsync`.

`SELFTEST_BUILD_OPTIONS` passes make arguments, including userspace compiler
settings. Kernel `CC`, `HOSTCC` and `HOSTCFLAGS` do not apply. Host builds use
`CROSS_COMPILE`; chroot builds use the rootfs's native toolchain. Kernel
cleaning may also remove selftest intermediates.

Module builds need a toolchain that supports the selected kernel and must
be able to run its build helpers. Build errors are reported normally; there
is no automatic fallback to another root.

## LTP

Set `LTP_GIT` in `setup.conf` to an LTP worktree, or set `LTP_DIR` per test.
Include `include/ltp.conf` and add `${BUILD_LTP}` to `POST_BUILD_APPEND`:

```conf
ARCH := arm64
INCLUDE ${THIS_DIR}/include/defaults.conf
INCLUDE ${THIS_DIR}/include/ltp.conf

DEFAULTS OVERRIDE
ROOT_DISK = /path/to/aarch64.img
CHROOT_USER = /path/to/aarch64/rootfs
LTP_TARGETS = testcases/kernel/syscalls/getpid
POST_BUILD_APPEND = ${BUILD_LTP}

TEST_START
TEST_TYPE = test
TEST = ${SSH} env LTPROOT=/mnt/build/ltp /mnt/build/ltp/testcases/bin/getpid01
```

LTP builds out of tree in `LTP_BUILD_DIR` (default `TMP_DIR/ltp`), outside the
kernel output. It installs into `OUTPUT_DIR/ltp`, seen by the guest as
`/mnt/build/ltp`. The worktree must not be configured in-tree. Each run
refreshes autotools on the host and reruns configure with `--config-cache`,
then builds incrementally. Autoconf saves probe results in
`LTP_BUILD_DIR/config.cache` for subsequent runs; the first configuration
still runs all probes.

Set `CHROOT_USER` to a rootfs matching the guest; an empty value builds on
the host. Kernel compiler settings do not apply. `LTP_CONFIGURE_OPTIONS`
passes configure arguments, including explicit `--host` and `CC=...` for
cross-builds. These options follow the defaults; add `--cache-file=/dev/null`
to disable caching. `LTP_BUILD_OPTIONS` passes make arguments.

`LTP_TARGETS` selects source-relative directories to build and install. Empty
means the full tree. Subset builds prepare the common LTP library first;
other declared library dependencies are handled by LTP's makefiles. Include
shell infrastructure and helpers explicitly, for example:

```conf
LTP_TARGETS = testcases/lib testcases/network/nfs/nfs_stress testcases/kernel/fs/fsstress
```

Subset mode skips the top-level installation; run selected tests directly.
Existing installed files are not removed. Unknown directories and build
failures stop the run; there is no full-build fallback.

Use a separate config file to get a fresh workspace after changing
architecture, build root, toolchain or compiler flags. If `LTP_BUILD_DIR` is
explicitly set, use a fresh directory too. After installing or updating build
dependencies, remove `LTP_BUILD_DIR/config.cache` before the next build so
configure refreshes its probe results.

## Sample

`tests/tumbleweed` demonstrates build, boot, chroot, BPF and LTP modes with
Tumbleweed x86_64 image/rootfs paths. It is a sample, not the entrypoint for
unrelated work; create task-specific tests instead. Select a sample mode by
editing its existing `TEST := build` assignment, for example:

```conf
TEST := ltp
```

Set the disk, rootfs and other settings in the file, then run:

```bash
kt -n tumbleweed
kt tumbleweed
```

`manual` keeps the VM running for interactive SSH access; Ctrl-C ends the run.

## Agent skill

[SKILL.md](SKILL.md) provides a kernel-testing and defect-reproduction workflow
for agents supporting Agent Skills. Load it with your agent and provide a
test goal or report while working in the kernel worktree.
