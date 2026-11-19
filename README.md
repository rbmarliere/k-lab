# k-lab

Kernel build/boot/test loops with
[ktest.pl](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest)
and [virtme-ng](https://github.com/arighi/virtme-ng). `ktest.pl` handles
builds, monitoring, iteration, bisect and patchcheck; `virtme-ng` boots and tests the
kernel against a disk image.

## Why?

Checking a kernel change usually means building it, booting it with suitable
userspace, running a reproducer or test suite, and inspecting the result.
Checking a fix repeats that cycle; finding a regression may repeat it across
many revisions.

`k-lab` connects these steps through a test configuration. You work in the kernel
source tree you want to test, while `ktest.pl` drives the build and test
sequence and `virtme-ng` boots the resulting kernel in a VM. The test command
runs over SSH, and `ktest.pl` records its result and logs.

```text
kernel worktree + test configuration
                 |
               build
                 |
       boot with your userspace image
                 |
        run test command over SSH
                 |
           result and logs
```

You provide the userspace image and the test, which can be a small reproducer
script or a suite such as kselftests or LTP. The image supplies userspace, not
the kernel under test: there is no need to install each kernel revision into
it.

## Setup

Optionally edit `setup.conf`, then:

```bash
./setup.sh
source /path/to/k-lab/k-lab.sh
```

Setup downloads the latest upstream `ktest.pl` into `tools/ktest/` on each run
unless `tools/ktest` is a symlink. It also clones missing `virtme-ng` and
busybox-builder checkouts. It does not install packages or provision root
filesystems. Existing local checkouts can be symlinked into `tools/` instead.

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

Set `VNG = /path/to/vng` in `setup.conf` or a test config to select another
executable. Install the build tools and `virtme-ng` dependencies yourself; see the [virtme-ng
documentation](https://github.com/arighi/virtme-ng#readme).

## Tests

For full syntax, see `ktest.pl`
[sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf)
and
[examples](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples/README).

A test consists of a `ktest.pl` configuration and any supporting fragments and
reproducer scripts. A typical layout is `tests/my-test/test`, with supporting
files alongside it. Several related configurations can share one directory.

Keeping architecture, image and rootfs paths, toolchain, resources and test
settings in the configuration makes runs repeatable. Advanced command-line
overrides are also available; see [Run](#run).

Declare `ARCH := ...` before the first `INCLUDE`, including native builds. `kt`
supplies `KLAB_DIR`, the path to the `k-lab` checkout; use `${KLAB_DIR}` for
references to its includes and test files.

For example, `tests/my-test/test`:

```conf
ARCH := x86_64
INCLUDE ${KLAB_DIR}/include/defaults.conf

DEFAULTS OVERRIDE
ROOT_DISK = /path/to/x86_64.img
POST_BUILD_APPEND = cp ${KLAB_DIR}/tests/my-test/run.sh ${OUTPUT_DIR}/run.sh

TEST_START
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh
```

Here, `POST_BUILD_APPEND` copies `run.sh` into the build output, which is
available in the guest as `/mnt/build`. The SSH test command runs from that
directory. The script's exit status supplies the result: zero for success,
nonzero for failure.

Use these `*_APPEND` settings to add commands without replacing the
corresponding `ktest.pl` hook:

- `PRE_KTEST_APPEND`
- `PRE_BUILD_APPEND`
- `POST_BUILD_APPEND`
- `PRE_INSTALL_APPEND`
- `POST_INSTALL_APPEND`
- `PRE_TEST_APPEND`
- `POST_TEST_APPEND`
- `POST_KTEST_APPEND`

A configuration can contain several cases selected with `ktest.pl`
conditionals. With common includes and settings above the sections, this
example selects between two script modes through the `TEST := ...` assignment:

```conf
DEFAULTS IF NOT DEFINED TEST
TEST := baseline

TEST_START IF ${TEST} == baseline
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh baseline

TEST_START IF ${TEST} == stress
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh stress
```

Edit the selector before starting a run, or inline through `-D TEST:=stress`.
All cases in one test config share a workspace. For parallel runs, see
[Workspaces and build reuse](#workspaces-and-build-reuse).

## Run

Run from the kernel worktree, selecting a test configuration:

```bash
kt -n my-test  # dry-run, show resolved options only
kt my-test     # build and run the configured test
kt -C my-test  # rebuild without cleaning
```

By default, each run cleans the kernel build with `make mrproper`, even if the
source has not changed. `-C`, or `BUILD_NOCLEAN = 1` in the test config or
profile, skips that cleaning step and reuses build objects.

`compile_commands.json` is generated in `OUTPUT_DIR` by default and linked from
the kernel source directory (`BUILD_DIR`). The latest build selects the active
database. Set `COMPILE_COMMANDS = 0` in the test config to disable generation.

Select a test by its name under `tests/` (`kt` tab completion via sourced
`k-lab.sh` works), a test config path, or a directory containing a `test` file.
Command-line flags control execution and provide advanced overrides:

- `-C` sets `BUILD_NOCLEAN=1`; `-n` prints resolved options; `-y` disconnects
  stdin.
- `-b` runs in the background, implies `-y`, and captures stdout/stderr in
  `TMP_DIR/ktlog`.
- `-D` passes option overrides to `ktest.pl`.

Background runs support immediate status checks and bounded waits:

```bash
kt -b my-test
kt status my-test
kt wait my-test
kt kill my-test
```

`status` reports immediately, `wait` waits up to 300 seconds by default (`-t`
changes this), and `kill` requests graceful cancellation of the whole run.
Run all three from the same kernel worktree with the same test config used
for launch.

While a run is active, `kt status` prints `status=running` and returns 0. If
`kt wait` times out, it returns 124 without stopping the run.

On completion, `kt` records the run's exit code in `TMP_DIR/status`. Both
commands return that code and show the log paths and the last 40 lines of each
available test log. If cleanup never runs, no final exit code is recorded.

## Logs and artifacts

With the `k-lab` defaults, `TMP_DIR` can contain:

- `buildlog-*`: compiler and build output.
- `dmesg-*`: captured guest console/kernel output.
- `ktestlog`: `ktest.pl` phase decisions and combined output.
- `ktlog`: background runner stdout/stderr, including launch errors.
- `testlog-*`: test command output and assertions.
- `vnglog`: VM launch and boot output.
- `failures/<run>/`: available logs (`testlog`, `buildlog`, `dmesg`, `logfile`)
  and kernel `config` saved by `ktest.pl` for a failed run.
- `successes/<run>/`: the same files for a successful run.

## VM behavior

Boots require `ROOT_DISK`, a raw or qcow2 image. `virtme-ng` handles the boot
parameters and module exposure. The minimum kernel fragment comes from `vng
--kconfig --dry-run`.

Use `VNG_QEMU_OPTS` to pass additional options to QEMU. It’s empty by default.

With `VNG_SNAPSHOT = 1` (the default), guest writes to the `ROOT_DISK` image
are discarded when the VM stops. Set `VNG_SNAPSHOT = 0` to let writes persist.

Guest path exports, always persistent independently of `VNG_SNAPSHOT`:

- `/mnt/src`: kernel source, read-only
- `/mnt/build`: build output, writable; also the SSH working directory

For other image layouts, set `VNG_ROOT_DEV` (default `/dev/vda`) and
`VNG_ROOT_FSTYPE` (default `ext4`), and enable the chosen filesystem in the
kernel config.

`VNG_MEM` defaults to `1G` of memory.

`VNG_ARGS` may be used to pass forward other flags to `virtme-ng`, such as
`--cpus 4 --systemd`.

For interactive SSH, the run's `TMP_DIR/ssh` helper is configured with its
workspace and port. While the run is active, `kt` links to it as
`ssh-<workspace>` in the directory where you launched the run.

Each VM launch records the shell-quoted `virtme-ng` invocation in
`TMP_DIR/cmdline-vng` and a `QEMU` command preview in `TMP_DIR/cmdline-qemu`.
Both include the wrapper's defaults and the run's options. A failed preview
prevents launch. Temporary socket and file-descriptor paths in the preview
differ from the actual launch.

## Workspaces and build reuse

`kt` keeps each workspace (`TMP_DIR`) in `tmp/<worktree>-<config>` under the
`k-lab` checkout. Conditional cases in one config share a workspace. Concurrent
runs need separate configs, workspaces, output directories and `VNG_PORT`
values (default 22000; no automatic port allocation).

Build output defaults to `OUTPUT_DIR = ${TMP_DIR}/build`. Tests can share a
kernel build by setting the same `OUTPUT_DIR`, while keeping logs and status in
their own `TMP_DIR`. `kt` locks both directories to prevent simultaneous use.
When switching toolchains, build roots, or source trees, clean before reusing
`OUTPUT_DIR` or use a fresh one.

Profiles under `profiles/` are optional, reusable configuration includes, just
like those in `include/`, but aimed for specialized build settings and rootfs
paths. Most profiles are local, like tests; `profiles/tumbleweed-x86_64.conf`
is the tracked example.

## Architecture and toolchains

Supported kernel architecture names are `x86_64`, `arm64`, `arm`, `powerpc`,
`s390`, and `riscv`. `CROSS_COMPILE` defaults to empty. Set it explicitly in
the test config or build profile for cross-builds, for example `CROSS_COMPILE =
aarch64-linux-gnu-`.

`CC`, `HOSTCC`, and `HOSTCFLAGS` apply to every `MAKE_CMD` invocation. Empty
values leave the makefile defaults in effect; nonempty values are passed as
make arguments.

Set `MAKE_CMD` for other persistent kernel build options, and invoke
`${MAKE_CMD}` in hooks that call kernel `make` so they use the same settings.

```conf
DEFAULTS OVERRIDE
MAKE_CMD = ${RUN} ${KLAB_DIR}/bin/make LLVM=1 LD=ld.lld KCFLAGS="-O1 -g"
```

`${RUN}` passes the build and VM settings from `k-lab` to the command as
environment variables.

`BUILD_OPTIONS` supplies extra arguments only for the kernel build, such as
parallelism or additional targets. It does not apply to configuration or other
make invocations and is not exported to hooks.

## Chroot builds

Kernel and userspace builds run on the host by default. Set `CHROOT_KERNEL`
when the kernel needs a different build environment, such as an older
distribution's toolchain. `CHROOT_USER` inherits `CHROOT_KERNEL`; set it
separately when that environment can't build test binaries compatible with the
guest libraries in `ROOT_DISK`. The root disk image supplies the VM's runtime
filesystem and is needed only for VM boots.

When `CHROOT_KERNEL` points to a rootfs directory, `MAKE_CMD` runs there for
configuration, kernel builds, and headers. Kernel builds in a chroot ignore the
configured `CROSS_COMPILE` prefix. Compilers selected with `CC` or `HOSTCC`
must be available inside that rootfs.

Use `${RUN_USER}` to build standalone guest programs; kernel compiler settings
don't apply:

```conf
DEFAULTS OVERRIDE
CHROOT_USER = /path/to/guest/rootfs
POST_BUILD_APPEND = cp ${KLAB_DIR}/tests/my-test/repro.c ${OUTPUT_DIR}/ && ${RUN_USER} gcc -o ${OUTPUT_DIR}/repro ${OUTPUT_DIR}/repro.c
```

Each rootfs gets a writable overlay under `TMP_DIR/chroot/`. The mounts
disappear when the command exits, but the overlay changes persist. The base
rootfs is not modified. Source and output are mounted at their host paths;
`bin/chroot` also binds the space-separated paths in `CHROOT_BINDS`.

The whole rootfs must be owned by the invoking user and contain the build
dependencies. Chroot builds need unprivileged user namespaces, overlayfs, and
util-linux with `--forward-signals`. Foreign roots also need host
qemu-user/binfmt registration.

## Selftests

Include `include/selftests.conf`, set `SELFTEST_TARGETS`, and add
`${BUILD_SELFTESTS}` to `POST_BUILD_APPEND`, e.g.:

```conf
DEFAULTS OVERRIDE
CHROOT_KERNEL =
CHROOT_USER = /path/to/guest/rootfs
SELFTEST_TARGETS = fchmodat2
POST_BUILD_APPEND = ${BUILD_SELFTESTS}
```

`SELFTEST_SOURCE` defaults to `BUILD_DIR`. Set it to another complete Linux
source tree to build newer collections without changing the kernel under test:

```conf
SELFTEST_SOURCE = /path/to/linux-mainline
SELFTEST_TARGETS = mm net
```

Keep that checkout at the revision you want; `k-lab` does not fetch or update
it. The source path and git revision are logged before building headers.

Headers from `SELFTEST_SOURCE` are generated into `TMP_DIR/selftests/headers`,
then the selected collections build with userspace intermediates in
`TMP_DIR/selftests/build`. Both steps run in `CHROOT_USER`, with external
source and workspace paths bound into the chroot. `O` and `KDIR` still point at
the prepared output of the kernel under test for module builds; module output
follows each collection's rules.

Installed tests remain at `/mnt/build/kselftest/kselftest_install`. The build
root needs the target collections' dependencies, including `make`, a compiler
and `rsync`.

`SELFTEST_BUILD_OPTIONS` passes make arguments to both header generation and
collection builds, including compiler settings such as `CC=gcc-15
HOSTCC=gcc-15`. Kernel `MAKE_CMD`, `CC`, `HOSTCC` and `HOSTCFLAGS` settings do
not apply.

## LTP

Set `LTP_SOURCE` in `setup.conf` for a default LTP worktree, or set it in the
test config. Include `include/ltp.conf` and add `${BUILD_LTP}` to
`POST_BUILD_APPEND`, for example:

```conf
ARCH := x86_64
INCLUDE ${KLAB_DIR}/include/defaults.conf
INCLUDE ${KLAB_DIR}/include/ltp.conf

DEFAULTS OVERRIDE
ROOT_DISK = /path/to/x86_64.img
CHROOT_USER = /path/to/x86_64/rootfs
LTP_SOURCE = /path/to/ltp-worktree
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
`LTP_BUILD_DIR/config.cache` for subsequent runs; the first configuration still
runs all probes.

Set `CHROOT_USER` to a rootfs matching the guest; an empty value builds on the
host. Kernel compiler settings do not apply to LTP userspace.
`LTP_CONFIGURE_OPTIONS` passes configure arguments, including explicit `--host`
and `CC=...` for cross-builds. These options follow the defaults; add
`--cache-file=/dev/null` to disable caching. `LTP_BUILD_OPTIONS` passes make
arguments.

Kernel modules use `OUTPUT_DIR` and its generated kernel release, not the
host's running kernel. They build in `CHROOT_USER` with the target `ARCH` (and
`CROSS_COMPILE` for host builds). The compiler there must support the tested
kernel's build requirements. Separate module output requires Kbuild's
`KBUILD_EXTMOD_OUTPUT` support; otherwise configuration stops with an error.
Set `LTP_CONFIGURE_OPTIONS = --without-modules` to build userspace only.
Modules are disabled automatically when the tested kernel lacks
`CONFIG_MODULES=y`.

Each run discards generated `.ko` files and `.dep_modules` stamps from the LTP
build and install directories, so modules cannot survive a kernel change or a
failed rebuild. Userspace remains incremental.

`LTP_TARGETS` selects source-relative directories to build and install. Empty
means the full tree. Subset builds prepare the common LTP library first; other
declared library dependencies are handled by LTP's makefiles. Include shell
infrastructure and helpers explicitly, for example:

```conf
LTP_TARGETS = testcases/lib testcases/network/nfs/nfs_stress testcases/kernel/fs/fsstress
```

Subset mode skips the top-level installation; run selected tests directly.
Existing installed userspace files are not removed; only modules built by the
selected targets are retained. Unknown directories and build failures stop the
run; there is no full-build fallback.

Changing `LTP_SOURCE` does not change the build or install directories. For a
clean comparison between worktrees, use a fresh `LTP_BUILD_DIR` and start with
an empty `OUTPUT_DIR/ltp`. Sequential runs can reuse the same test config and
kernel build.

Use a fresh `LTP_BUILD_DIR` when changing architecture, build root, toolchain
or compiler flags. After installing or updating build dependencies, remove
`LTP_BUILD_DIR/config.cache` so configure refreshes its probe results.

## SUSE kernel configuration

`include/suse.conf` provides SUSE product configuration. `SUSE_BRANCH` selects
the worktree directory, which must exist below `SUSE_KERNEL_SOURCE_GIT`
configured in `setup.conf`. `SUSE_FLAVOR` selects the kernel config filename,
defaulting to `default`. `SUSE_VERSION` and `SUSE_PATCHLEVEL` are unset for
Tumbleweed and set together for SLE.

These settings can be bundled with toolchain and path options in a
[build profile](#workspaces-and-build-reuse).

The SUSE include supplies the flavor through `ADD_CONFIG`. To add test-specific
fragments without replacing it, retain the inherited list after `TEST_START`:

```conf
TEST_START
TEST_TYPE = build
ADD_CONFIG = ${ADD_CONFIG} ${KLAB_DIR}/tests/my-test/extra.config
```

A plain per-test `ADD_CONFIG = ...` replaces the flavor fragment. This
self-reference retains it only in a test section; do not use it to redefine
`ADD_CONFIG` in `DEFAULTS OVERRIDE`. Later fragments override earlier ones;
`MIN_CONFIG` takes precedence over all `ADD_CONFIG` fragments.

## Sample

[The Tumbleweed sample](tests/tumbleweed/test) includes the [x86_64
profile](profiles/tumbleweed-x86_64.conf), which selects the SUSE `stable`
kernel config and sets `ROOT_DISK` to
`${ROOTS_DIR}/opensuse/tumbleweed/x86_64.img`. Set `SUSE_KERNEL_SOURCE_GIT` in
`setup.conf` to the tree containing `stable/config/x86_64/default`. Only modes
that boot a VM need the disk image.

From the kernel worktree:

```bash
kt tumbleweed                   # build on the host; no VM
kt -n -D TEST:=boot tumbleweed  # inspect the boot settings
kt -D TEST:=boot tumbleweed     # build, boot and check /dev/vda
kt -D TEST:=manual tumbleweed   # boot and keep the VM running
```

Use `-D TEST:=<mode>` for one run, or edit `TEST := build` in the test file to
change the default.

The test file sets the chroot paths per mode. `chroot` and `chroot-boot` build
the kernel in `${ROOTS_DIR}/opensuse/tumbleweed/x86_64`; `ltp` uses that rootfs
to build LTP, not the kernel. `bpf` runs the `bpf:test_progs` selftest.

All modes share `tmp/build-tumbleweed-x86_64` and skip cleaning by default. See
[build reuse](#workspaces-and-build-reuse) before switching build environments.

## Agent skill

[SKILL.md](SKILL.md) provides a kernel-testing and defect-reproduction workflow
for agents supporting Agent Skills. Load it with your agent and provide a
test goal or report while working in the kernel worktree.
