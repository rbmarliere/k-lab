# k-lab

Kernel build/boot/test loops with `ktest.pl` and `virtme-ng`. ktest handles
builds, monitoring, iteration, bisect and patchcheck; vng boots the kernel
against a disk image with `--root-disk`.

## Setup

Edit `setup.conf`: `THIS_DIR` is this checkout, `LINUX_GIT` supplies ktest, and
optional `KSOURCE_GIT` supplies SUSE configs. Then:

```bash
./setup.sh
source /path/to/k-lab/k-lab.sh
```

Setup links ktest and clones missing virtme-ng and busybox-builder checkouts.
It does not install packages or provision root filesystems. Existing local
checkouts can be symlinked into `tools/` instead.

Provide a static busybox for every guest architecture. On openSUSE, the
external builder can prepare dependencies and build it:

```bash
cd tools/busybox-static-builder
./prepare x86_64   # may install packages with sudo/zypper
./build x86_64
```

Override `BUSYBOX` per test or with `kt -D BUSYBOX=/path/to/static/busybox`.
`VNG = /path/to/vng` selects a different executable. Install the build tools
and vng dependencies yourself; see the [vng documentation](https://github.com/arighi/virtme-ng#readme).

## Tests

Write a separate test under `tests/` for each task. Keep its ktest config,
fragments, and reproducer files together. For example, `tests/my-test/test`:

```conf
INCLUDE ../../include/defaults.conf

DEFAULTS OVERRIDE
ROOT_DISK = /path/to/image.img
POST_BUILD_APPEND = cp ${THIS_DIR}/tests/my-test/run.sh ${OUTPUT_DIR}/run.sh

TEST_START
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh
```

Put verdict logic in `run.sh` and return a meaningful exit status. For a
build-only check, use `TEST_TYPE = build`; no image or guest script is needed.
Extend phase hooks with their corresponding `*_APPEND` options.

Include `include/suse.conf` after defaults for SUSE product configuration. Set
`BRANCH = stable` or the relevant config-tree directory. Leave `VERSION` and
`PATCHLEVEL` unset for Tumbleweed, or set both for SLE.

For full syntax, see ktest's [sample.conf](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/sample.conf) and
[examples](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/tools/testing/ktest/examples/README).

## Run

Run from the kernel worktree, selecting your task's test:

```bash
kt -n my-test                          # resolved options only
kt my-test                             # build and run the configured test
kt -C my-test                          # rebuild without cleaning
kt -D COMPILE_COMMANDS=0 my-test       # skip compile_commands.json
kt -D ARCH:=arm64 \
   -D CROSS_COMPILE=/path/to/aarch64-linux-gnu- \
   my-test
```

`compile_commands.json` is generated in `OUTPUT_DIR` by default and linked
from the kernel source directory (`BUILD_DIR`). The latest build selects the
active database. Set `COMPILE_COMMANDS=0` to disable generation and leave any
existing link unchanged.

Without a test argument, `kt` performs a host defconfig build. Test arguments
may be names under `tests/`, paths to configs, or directories containing a
`test` file.

- `-D name=value` forwards normal ktest options, including per-test `[N]`
  overrides.
- `ARCH` uses `:=`; set it before including defaults in a config.
- `-C` sets `BUILD_NOCLEAN=1`; `-n` prints resolved options; `-y` disconnects
  stdin.
- `-b` runs in the background, implies `-y`, and captures stdout/stderr in
  `TMP_DIR/ktlog`.

Background runs support immediate status checks and bounded waits:

```bash
kt -b my-test
kt status my-test
kt wait my-test
```

`status` reports immediately; `wait` waits up to 300 seconds by default (`-t`
overrides this). Both resolve `[test]` exactly like a run. With a custom
`TMP_DIR`, repeat `-D TMP_DIR=/absolute/path`. Run these commands from the
same kernel worktree as the launch.

Completed runs save `exit=<code>` in `TMP_DIR/status`. Both commands return
that exit code and print log paths and the last 40 lines of any
`testlog-*` files. These are runner exit codes, not independent kernel
verdicts. Logs are ktest-managed and may remain from an earlier run if the
current run never reached that phase. While running, `status` returns 0; `wait`
returns 124 on timeout, without stopping the run. Runs interrupted before
cleanup (for example, SIGKILL) have no completed exit status.

`ARCH` defaults to the host. Supported kernel architecture names are `x86_64`,
`arm64`, `arm`, `powerpc`, `s390`, and `riscv`. Disk names and chroot contents
do not select the architecture. Foreign host builds use SUSE compiler prefixes
by default; override `CROSS_COMPILE` as needed.

`CC`, `HOSTCC`, and `HOSTCFLAGS` apply to every make invocation. Empty values
leave the makefile defaults in effect; nonempty values are passed as make
arguments. Chroot builds ignore the configured `CROSS_COMPILE` prefix.

`TMP_DIR` defaults to `tmp/<worktree>-<config>` and is protected by `flock`.
Override with `-D TMP_DIR=/absolute/path`; `kt -n` shows the resolved path.
Use separate `TMP_DIR` directories, output directories, and `VNG_PORT` values
for concurrent runs. The default SSH port is 22000; there is no automatic
port allocation.

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

Ctrl-C stops the run and its VM. While a run is active, another TTY can open
an SSH shell or stop the VM using the run's TMP_DIR and VNG_PORT:

```bash
TMP_DIR=/path/to/tmp-dir VNG_PORT=22000 /path/to/k-lab/bin/vm exec
TMP_DIR=/path/to/tmp-dir /path/to/k-lab/bin/vm stop
```

Each VM launch records the shell-quoted vng invocation in `TMP_DIR/cmdline-vng`
and a QEMU command preview in `TMP_DIR/cmdline-qemu`. Both include the
wrapper's defaults and the run's options. A failed preview prevents launch.
Temporary socket and file-descriptor paths in the preview differ from the
actual launch.

`kt -n <test>` prints configured RAM, CPUs (`VNG_ARGS`), disk, architecture,
and snapshot settings without launching a VM.

`bin/kt-kill <TMP_DIR>` requests graceful cancellation of the whole run.

## Chroot builds

Set `CHROOT_BUILD = 1` and `CHROOT = /path/to/rootfs`. Each make command runs
in an unprivileged user/mount/PID namespace with a writable overlay over that
rootfs. `TMP_DIR` retains overlay changes; mounts vanish when the command
exits. The rootfs is not modified. Source and output are bound in at their host
paths, and builds use the chroot's native toolchain, not `CROSS_COMPILE`.

The rootfs must be user-owned and contain the build dependencies. This needs
host support for unprivileged user namespaces and OverlayFS mounts, and a
recent util-linux with `--forward-signals`. Foreign chroots also need host
qemu-user/binfmt registration.

## Sample

`tests/tumbleweed` demonstrates build, boot, chroot, and BPF modes with Tumbleweed
x86_64 image/rootfs paths. It is a sample, not the entrypoint for unrelated
work; create task-specific tests instead. For example:

```bash
kt -D TEST:=boot tumbleweed
kt -D TEST:=manual tumbleweed
```

`manual` keeps the VM running for interactive SSH access; Ctrl-C ends the run.
The sample's `TEST` selector uses `:=`. Override `ROOT_DISK` and `CHROOT` for
your machine.
