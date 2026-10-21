---
name: k-lab
description: Build, boot, and test kernel worktrees with k-lab. Use when asked to verify kernel behavior or reproduce a reported defect.
---

# k-lab

## Goal

Use k-lab to build the current kernel worktree, optionally boot it, and verify
behavior or reproduce a reported defect. Read any supplied report, log, or
commit first; identify the exact trigger and assertion. Ask only for
information needed to proceed, including the goal or a ROOT_DISK for boot tests
if neither can be established from the task or an existing test.

Tool output stays in context for the rest of the session. Find evidence with
`grep -n`, `wc -l`, and bounded line ranges; do not print whole logs, file
listings, or verbose command output.

Verification should pass; reproduction should trigger the specified defect on
the unfixed tree and pass once fixed. A passing test does not establish root
cause, and an unrelated failure is not a reproduction.

## Baseline first

Validate supplied paths and configured tools before investigating internals.
Confirm substitutions for missing inputs. Once the upstream command, build
dependencies and required kernel options are known, create the config,
check `kt -n`, and launch one unchanged baseline. Defer history searches and
generic CI/harness investigation until an observed failure requires them.

Before launching, record the reported failure signature from the job log:
exact messages, source locations, failing phase and elapsed time. If the log
is unreachable, ask the user for the relevant excerpt; do not proceed on a
summary alone.

Run the test through its own entry point with the arguments the job used,
unmodified. Add instrumentation, loops or wrappers only after the baseline
result is known.

If ARCH differs from the host, the guest runs under QEMU TCG without KVM.
Before launching, state this, the emulated CPU model and the expected
slowdown as unmatched job conditions. For timing-sensitive defects, say that
reproduction is unlikely and ask whether to proceed.

## Prepare the test

Unless specified otherwise, use the session's initial CWD as the selected
kernel worktree. Resolve its Git root and run all `kt` commands there. If CWD
is not a kernel worktree, ask for its path; do not search.

Resolve this `SKILL.md` once with `realpath` to follow symlinks. Its containing
directory is the k-lab checkout. Resolve k-lab file references below against
that directory, not the kernel worktree; do not search for another checkout.

Read `README.md` for current usage, options, and SUSE configuration.
Read `setup.conf` for the configured `LINUX_GIT`; consult
`tools/testing/ktest/sample.conf` and `tools/testing/ktest/examples/README` in
that kernel tree only for deeper ktest syntax. Do not inspect or modify harness
source unless asked; searching the kernel code and its history is expected.
Harness means k-lab (`bin/`, `tools/`, ktest) and the test suite's shared
library and helpers. Read the latter only when a failure matching the reported
signature points into it.

Keep all run configuration in the test file and its includes: architecture,
disk and rootfs paths, toolchain, resources, workspace, target selection and
iteration counts. Never use `kt -D` or shell-prefix environment assignments
to supply test settings at launch. The command line selects the config and
controls execution (`-n`, `-b`, `-C`, `-y`, and wait `-t`). Use separate
config files for variants rather than command-line overrides.

Throughout this skill, `kt` means the resolved absolute path to `bin/kt`.
Run it directly from the kernel worktree root; do not source `k-lab.sh` or
assume `kt` is on PATH. Create a task-specific `tests/<name>/` with a
`test` config, fragments, and reproducer files unless the user selects an
existing test to reuse. Keep verdict logic in a standalone script: exit 0 for
expected behavior, nonzero for a violated assertion, and distinguish setup
errors from the defect. Keep the output of setup and preceding steps (in the
test log or under `/mnt/build`) rather than discarding it, and record the
relevant system state immediately before the assertion when the defect may
depend on resources.

Minimal boot-test config (replace `example` and the image path):

```conf
ARCH := x86_64
INCLUDE ${THIS_DIR}/include/defaults.conf

DEFAULTS OVERRIDE
ROOT_DISK = /path/to/x86_64.img
POST_BUILD_APPEND = cp ${THIS_DIR}/tests/example/run.sh ${OUTPUT_DIR}/run.sh

TEST_START
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh
```

For build-only checks, use `TEST_TYPE = build`; no disk or guest script is
needed. The kernel comes from this worktree; ROOT_DISK supplies guest
userspace.

- Declare `ARCH := ...` before the first INCLUDE, even for native builds;
  disk names do not select it.
- Use normal `=` options for ROOT_DISK, CHROOT_KERNEL, and CROSS_COMPILE.
  A nonempty `CHROOT_KERNEL = /path/to/rootfs` selects chroot builds for
  everything run through MAKE_CMD; an empty CHROOT_KERNEL selects host
  builds. Choose the rootfs explicitly; do not derive it from the disk
  filename or assume its packages match the guest. Chroot builds use the
  rootfs's native toolchain and ignore CROSS_COMPILE. Build guest programs
  with `${RUN_USER}`; `CHROOT_USER` (default CHROOT_KERNEL) selects their
  root, so the kernel can build on the host while they build against the
  guest's libraries. `${BUILD_SELFTESTS}` builds complete collections,
  including test modules, in `CHROOT_USER`. Headers come from `MAKE_CMD`;
  module builds use the prepared kernel output through `O` and `KDIR`.
  A rootfs not owned entirely by the invoking user fails with mount or
  permission errors; report it as a setup blocker.
- Guest paths are `/mnt/src` (read-only source) and `/mnt/build` (writable
  output, also the SSH working directory). Stage task files into OUTPUT_DIR on
  the host.
- Extend phases with `*_APPEND`; replace a whole hook only deliberately.
- Concurrent runs need distinct TMP_DIR values and, for VMs, VNG_PORT values.
  There is no automatic port allocation.
- Keep default disk snapshots. Save results under `/mnt/build`; other guest
  filesystem changes disappear when the VM stops.
- `RUN_TIMEOUT` (ktest.pl) bounds every command ktest runs via `run_command`,
  including `make mrproper`/the build itself, not just the final SSH test
  command. A value sized for the test step alone can abort mid-build. Leave
  it unset unless it is also sized for a from-scratch build, and prefer `-C`
  (reuse build objects) over tightening `RUN_TIMEOUT` to avoid rebuild stalls.

## Run and iterate

1. Run `kt -n <name>/test` and check the resolved environment and TMP_DIR,
   including RAM, CPUs (`VNG_ARGS`), `--systemd`, disk, architecture, and
   snapshot settings.
2. Run `kt -b <name>/test` for long runs; retain the reported TMP_DIR and
   `ktlog` path. Use `kt -y <name>/test` for foreground runs. Without `-C`,
   every launch (including any relaunch of the same test, e.g. after a kill
   or a wait timeout) runs `make mrproper` first and rebuilds from scratch;
   pass `-C` to reuse existing build objects whenever the kernel tree and
   build environment have not changed.
3. Use `kt wait -t 240 <name>/test` for bounded waits. Repeat while it reports
   `status=running` and returns 124. Use `kt status <name>/test` for an immediate
   check; it returns 0 even while running, so check the reported status rather
   than the return code alone. Run both commands from the same kernel worktree
   as the launch, with the same config file. Keep that config unchanged until
   the run finishes. A timed-out wait leaves the run active; do not relaunch
   it or start a conflicting run. Confirm completion (`exit=<code>`) before
   interpreting results; a runner exit code or log pattern alone is not a
   kernel verdict.
4. Inspect the focused log for the failed phase rather than searching combined
   output: start with the test log for assertions, build log for compiler
   errors, VM log for boot problems, or runner log for background launch
   errors. See the README's "Logs and artifacts" section for filenames and
   archives. Verify that the logs belong to the current run; follow its `Saved
   info to` path rather than assuming the newest archive is relevant. Use
   `ktestlog` for ktest's phase decisions and the captured guest output for
   kernel diagnostics. For VM environment mismatches, inspect the recorded vng
   invocation and QEMU preview rather than bypassing the wrapper.
5. Default (`-C` omitted) always does a full clean rebuild (`make mrproper`),
   even for an unmodified tree; use it only for the first build of a test or
   after `ARCH`/compiler/build-environment changes. Reuse `-C` for every
   other relaunch with the same architecture, compiler, and build
   environment. After changing those, use a fresh TMP_DIR. Keep artifacts
   out of source commits; do not delete unrelated build state.

Compare every failure with the reported signature before investigating it.
A failure in a different phase or with a different message (test-suite
helpers, toolchain, C library, emulator) is a blocker, not evidence: report
it with the decisive output and stop. Do not debug test-suite tooling, the C
library, compilers or the emulator, and do not write new diagnostic programs,
without approval.

An attempt is any launch that does not reach the reported assertion. Stop
after three and report the blocker; ask before further attempts. An expected
defect is a valid reproduction result, not an unsuccessful attempt.

Know the expected test duration from the job log. Check the first
iteration's output before waiting on more. Bound each guest command with
`timeout` at a small multiple of the expected time; if a step exceeds it,
inspect it instead of extending `kt wait`.

## Boundaries and root cause

- Missing dependencies or incompatible environments are blockers, not kernel
  verdicts. Stop and report them. Do not run `setup.sh`, install packages,
  provision images, switch disks/build modes, or weaken assertions without
  approval.
- Match relevant job conditions (userspace, config, compiler, CPUs, services,
  swap, memory available at test start, preceding tests, security settings,
  load). For flaky defects, report failures/attempts, not just one green run.
- Guest changes made by the test script (swap, sysctls, memory fillers,
  services) are test conditions. Justify each from the report and list it in
  the result. A failure produced by imposing the hypothesized condition is a
  hypothesis check, not a reproduction of the job's failure.
- If asked why, establish code provenance, prerequisites, follow-ups, and
  relevant branch differences before proposing a fix. For patch queues, verify
  that the relevant patches are actually included in the series.
- Distinguish a backport, an adaptation, and original code. Consider
  completing, adapting, or reverting an incompatible change rather than
  assuming that adding code is the answer.
- Ask before original shared/core code, a whole-series backport, ABI/kABI
  changes, or a fix whose correctness the available evidence cannot establish.
  Symptom suppression and a correct fix are separate claims.

## Report

State the goal/assertion, test path, exact commands and environment, result or
reproduction rate, and artifact paths. List job conditions matched and not
matched, and any conditions the test imposed. Include decisive failure output.
If root causing was requested, give the provenance evidence and proposed
resolution. Always state what remains unverified; a green test alone is not
proof.
