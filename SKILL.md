---
name: k-lab
description: Build, boot, and test kernel worktrees with k-lab. Use when asked to verify kernel behavior, reproduce a reported defect, or run a selected test.
---

# k-lab

## Goal

Use k-lab to build the selected kernel worktree, optionally boot it, and verify
behavior, reproduce a reported defect, or run a selected test. Read any
supplied resource, such as a report, log, or commit first; identify the trigger
and assertion. Ask only for missing inputs needed to proceed, such as the goal
or `ROOT_DISK` for a boot test.

Tool output stays in context. Use `grep -n`, `wc -l`, and bounded line ranges;
do not print whole logs, file listings, or verbose command output.

Verification should pass. Reproduction should trigger the specified defect on
the unfixed tree and pass once fixed.

## Baseline first

Validate supplied paths and configured tools before investigating internals.
Confirm substitutions for missing inputs. Once the test command, build
dependencies and required kernel options are known, prepare and dry-run the
config, then launch one unchanged baseline. Defer history searches and generic
CI/harness investigation until an observed failure requires them.

Before launching, establish the command and expected result:

- **Reported job:** Record the exact failure messages, source locations,
  failing phase and elapsed time from the job log. If the log is unreachable,
  ask for the relevant excerpt; do not proceed on a summary alone. Run the test
  through its own entry point with the arguments the job used.
- **Selected test:** Identify the test source and revision, native entry point,
  arguments, prerequisites and expected behavior from the request, test or
  patch. No prior failure or job log is required. Where the suite supports it,
  build only the targets and helpers the selected test needs. If asked to
  compare kernels, run the same test revision and invocation on each specified
  worktree.

Run the test unmodified. Add instrumentation, loops or wrappers only after the
baseline result is known.

If `ARCH` differs from the host, the guest runs under QEMU TCG without KVM.
Before launching, state this, the emulated CPU model and the expected slowdown.
Flag these as unmatched conditions when reproducing a job. For timing-sensitive
defects, say that reproduction is unlikely and ask whether to proceed.

## Prepare the test

Use the session's initial CWD as the kernel worktree unless specified
otherwise. If it is not a kernel worktree, ask for the path; do not search.

Resolve this `SKILL.md` once with `realpath`. Its directory is the k-lab
checkout; resolve k-lab file references there, not in the kernel worktree. Do
not search for another checkout. Read its `README.md` in full and use its
configuration examples and build helpers. Consult the linked ktest sample and
examples only for deeper ktest syntax. The rules here govern agent workflow,
not the public interface.

Throughout this skill, `kt` means the absolute path to `bin/kt` in that
checkout. Run it directly from the selected worktree's Git root; do not
source `k-lab.sh` or rely on `PATH`.

Do not inspect or modify k-lab harness source (`bin/`, `tools/`, ktest) unless
asked. Read the test suite's shared library and helpers only when a matching
job failure or the selected test's failed assertion points there; do not modify
them unless asked. Kernel code and history are in scope.

Keep all run settings in the test config and its includes, including resources,
test targets and iteration counts. Never set them with `kt -D` or shell-prefix
environment assignments. Choose the architecture, disk, build roots and
toolchain explicitly. Do not infer a build root or compiler from an image
filename or assume that a rootfs has the guest libraries and build
dependencies.

Start each investigation in its own `tests/<name>/` with a `test` config and
any needed fragments or scripts, unless the user selects an existing k-lab
config. Use kebab-case (e.g. `tests/foo-bar`); do not search for reuse
candidates unless asked. Keep related experiments in the established directory
even if the hypothesis, kernel version, backend or subagent changes. Pass the
directory along in handoffs and delegation.

For related sequential variants with a compatible build environment, prefer
conditional `TEST_START` sections and an explicit `TEST := <variant>` selector
in the existing config. Use separate configs in the same investigation
directory when the baseline must remain unchanged, or for independent
workspaces, build environments, concurrency or readability. Temporary variants
follow the same directory rule. Share scripts and fragments where appropriate;
separate assertions may use separate scripts in the same directory.

Use an existing test's native verdict. For a custom reproducer, keep verdict
logic in a standalone script: exit 0 for expected behavior, nonzero for a
violated assertion, and distinguish setup errors from the defect. Preserve
setup and preceding output in the test log or under `/mnt/build`. When the
defect may depend on resources, record the relevant system state immediately
before the assertion.

- Write every `INCLUDE` path as `${KLAB_DIR}/...`, never relative.
- Stage task files in `OUTPUT_DIR`. Extend hooks with `*_APPEND`; replace a
  whole hook only deliberately.
- Keep build-affecting settings in the test config. Use or create a profile
  only at the user's explicit request. Use `-C` for relaunches with the same
  architecture, compiler and build environment. If any change, use a separate
  config with a fresh workspace and build output rather than changing a shared
  build.
- Let `kt` manage `TMP_DIR`. Before concurrent runs, check workspace, output
  directory and VM port isolation.
- Keep default disk snapshots. Use the run's `TMP_DIR/ssh` helper rather than
  assembling a separate SSH command. Save artifacts in the exported build
  output, not in source commits. Do not delete unrelated build state.

## Run and iterate

Leave `RUN_TIMEOUT` unset by default: it limits individual `ktest.pl` commands,
including kernel cleaning and building. Bound the guest command separately
(e.g. `TEST = ${SSH} timeout 300 sh ./run.sh`) based on the job log or the
test's expected runtime. Check the first iteration's output before waiting on
more. Inspect a guest timeout rather than extending the wait.

1. Run `kt -n <name>/test` and check `TMP_DIR` and the resolved environment:
   RAM, CPUs (`VNG_ARGS`), `--systemd`, disk, architecture and snapshots.
2. Run `kt -b <name>/test` for long runs; retain the reported `TMP_DIR` and
   `ktlog` path. Use `kt -y <name>/test` for foreground runs.
3. Use `kt status <name>/test` for immediate checks and
   `kt wait -t 240 <name>/test` for bounded waits. Use the launch worktree
   and config; keep the config unchanged while the run is active. A wait
   timeout does not stop the run: check it rather than relaunching. Confirm
   completion (`exit=<code>`) from the reported status, not the command return
   code. A runner exit code or log pattern alone is not a verdict.
4. Check the focused log for the failed phase: test for assertions, build for
   compiler errors, VM for boot problems, or runner for background launch
   errors. Follow this run's `Saved info to` path, not the newest archive. Use
   `ktestlog` for phase decisions and captured guest output for kernel
   diagnostics. For VM mismatches, inspect the recorded vng invocation and QEMU
   preview rather than bypassing the wrapper.

For job reproduction, compare every failure with the reported signature before
investigating. A different phase or message is a blocker, not kernel evidence.
For selected tests, report skips separately from passes and assertion failures.

Any environment issue is an immediate hard stop, whether found during setup or
a run. This includes ownership, mount, dependency, toolchain and compatibility
problems. Report the decisive output and ask the user how to proceed. Do not
repair the environment, switch `ROOT_DISK`, build roots or toolchains, or retry
without explicit user approval.

For non-environment failures, a launch that does not reach the intended
assertion counts as an attempt. Stop after three and ask before further
attempts. An expected defect is a valid reproduction result, not an
unsuccessful attempt.

## Boundaries and root cause

- Without approval, do not repair the environment, run `setup.sh`, install
  packages, provision images, switch disks or build modes, weaken assertions,
  debug test-suite tooling, the C library, compilers or the emulator, or write
  new diagnostic programs.
- When reproducing a job, match relevant conditions (userspace, config,
  compiler, CPUs, services, swap, memory available at test start, preceding
  tests, security settings, load).
- After the unchanged baseline, use controlled VM changes to test a specific
  hypothesis. For example, add `netem` delay to a test interface, pin the
  workload with `taskset` and add bounded CPU load, or introduce bounded guest
  memory pressure. Keep changes local to the test and vary one condition at a
  time where practical. Record what changed and compare the result with the
  control. If the imposed condition wasn't established for the original job,
  report a matching failure as a reproduction under those conditions, not as
  proof of what happened in the job.
- If asked why, establish code provenance, prerequisites, follow-ups, and
  relevant branch differences before proposing a fix. For patch queues, verify
  that the relevant patches are actually included in the series.
- Distinguish a backport, an adaptation, and original code. Consider
  completing, adapting, or reverting an incompatible change rather than
  assuming that adding code is the answer.
- Ask before original shared/core code, a whole-series backport, ABI/kABI
  changes, or a fix whose correctness the available evidence cannot establish.
  Symptom suppression and a correct fix are separate claims.
- Fix verification: if testing a candidate fix needs a tree other than the
  given worktree, do not create one. Report the reproduction, describe the fix,
  and request a decision (apply in the existing worktree, an approved scratch
  worktree, or skip).

## Report

State the goal and assertion, test path, exact commands and environment, and
artifact paths. For each run, give the kernel and (if applicable) suite
revisions, including any local patches, and the expected and observed verdict.
For flaky defects, report failures/attempts, not just one green run. List any
conditions the test imposed and, for a reported job, those that matched or
differed. Include decisive failure output. If asked for root cause, give the
provenance evidence and proposed resolution. State what remains unverified; a
green test alone does not establish root cause.
