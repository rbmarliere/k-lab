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
INCLUDE ${THIS_DIR}/include/defaults.conf

DEFAULTS OVERRIDE
ROOT_DISK = /path/to/image.img
POST_BUILD_APPEND = cp ${THIS_DIR}/tests/example/run.sh ${OUTPUT_DIR}/run.sh

TEST_START
TEST_TYPE = test
TEST = ${SSH} sh ./run.sh
```

For build-only checks, use `TEST_TYPE = build`; no disk or guest script is
needed. The kernel comes from this worktree; ROOT_DISK supplies guest
userspace.

- Set foreign `ARCH := ...` before INCLUDE; disk names do not select it.
- Use normal `=` options for ROOT_DISK, CHROOT, and CROSS_COMPILE.
  A nonempty `CHROOT = /path/to/rootfs` selects chroot builds; an empty CHROOT
  selects host builds. Choose the rootfs explicitly; do not derive it from
  the disk filename or assume its packages match the guest. Chroot builds use
  the rootfs's native toolchain and ignore CROSS_COMPILE.
- Guest paths are `/mnt/src` (read-only source) and `/mnt/build` (writable
  output, also the SSH working directory). Stage task files into OUTPUT_DIR on
  the host.
- Extend phases with `*_APPEND`; replace a whole hook only deliberately.
- Concurrent runs need distinct TMP_DIR values and, for VMs, VNG_PORT values.
  There is no automatic port allocation.
- Keep default disk snapshots. Save results under `/mnt/build`; other guest
  filesystem changes disappear when the VM stops.

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
   as the launch, with the same test argument and any `-D TMP_DIR=...` override.
   A timed-out wait leaves the run active; do not relaunch it or start a
   conflicting run. Confirm completion (`exit=<code>`) before interpreting
   results; a runner exit code or log pattern alone is not a kernel verdict.
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

Stop after three attempts that fail to produce a usable verdict and report
the blocker. An expected defect is a valid reproduction result, not an
unsuccessful attempt.

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
