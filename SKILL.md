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

Read `README.md` for current usage, options, and SUSE configuration. Consult
ktest's sample.conf and examples linked there only for deeper ktest syntax.
The README is the usage reference; the restrictions below govern agent
workflow, not which features the public interface supports.
Do not inspect or modify harness source unless asked; searching the kernel
code and its history is expected.
Harness means k-lab (`bin/`, `tools/`, ktest) and the test suite's shared
library and helpers. Read the latter only when a failure matching the reported
signature points into it.

Keep all run configuration in the test file and its includes: architecture,
disk and rootfs paths, toolchain, resources, target selection and iteration
counts. Never use `kt -D` or shell-prefix environment assignments to supply
test settings at launch. The command line selects the config and controls
execution (`-n`, `-b`, `-C`, `-y`, and wait `-t`).

Throughout this skill, `kt` means the resolved absolute path to `bin/kt`.
Run it directly from the kernel worktree root; do not source `k-lab.sh` or
assume `kt` is on PATH.

Start each new investigation in its own `tests/<name>/` with a `test` config,
fragments, and reproducer files unless the user selects an existing test.
Do not search existing tests for reuse candidates unless asked.
Once the investigation has a directory established by the conversation, user,
handoff or delegation, keep related follow-up experiments there. A new
hypothesis, kernel version, execution backend or subagent does not by itself
justify a sibling directory. Pass the established directory when delegating
follow-up work.

Prefer `TEST_START IF ${TEST} == <variant>` sections in the existing config
for related sequential variants with a compatible build environment. Keep an
explicit `TEST := <variant>` selector in the config. Use separate config files
within the same investigation directory when independent workspaces, build
environments, concurrency or readability warrant them. Share scripts and
fragments where appropriate; separate assertions may use separate scripts
without creating another investigation directory.

Keep verdict logic in a standalone script: exit 0 for expected behavior,
nonzero for a violated assertion, and distinguish setup errors from the defect.
Keep the output of setup and preceding steps (in the test log or under
`/mnt/build`) rather than discarding it, and record the relevant system state
immediately before the assertion when the defect may depend on resources.

Use the README's configuration examples and build helpers. Apply these
workflow safeguards:

- Write every INCLUDE path as `${THIS_DIR}/...`, never relative.
- Choose the architecture, disk, build roots and toolchain explicitly. Do not
  infer a build root or compiler from an image filename, or assume a rootfs
  has the guest's libraries and build dependencies.
- Stage task files into OUTPUT_DIR. Extend phases with `*_APPEND`; replace a
  whole hook only deliberately.
- Reuse a matching build profile from `profiles/`; add one if none matches.
  Keep build-affecting settings there, and give incompatible variants their
  own build output rather than changing a build shared by other tests.
- Let `kt` manage `TMP_DIR`. Before concurrent runs, check workspace, output
  directory and VM port isolation as described in the README.
- Keep default disk snapshots and save artifacts in the exported build output.
  Use the run's `TMP_DIR/ssh` helper rather than assembling a separate SSH
  command with independently configured settings.
- Report rootfs ownership, mount and dependency errors as setup blockers;
  do not repair the build environment without approval.
- Leave `RUN_TIMEOUT` unset unless it accommodates a from-scratch build.
  Bound guest commands separately rather than using a short global timeout.

## Run and iterate

1. Run `kt -n <name>/test` and check the resolved environment and TMP_DIR,
   including RAM, CPUs (`VNG_ARGS`), `--systemd`, disk, architecture, and
   snapshot settings.
2. Run `kt -b <name>/test` for long runs; retain the reported TMP_DIR and
   `ktlog` path. Use `kt -y <name>/test` for foreground runs.
3. Use `kt wait -t 240 <name>/test` for bounded waits and `kt status <name>/test`
   for immediate checks, from the same kernel worktree and with the same
   config as the launch. Keep the config unchanged while the run is active;
   check the reported status, not the command return code alone. A wait
   timeout is not completion or permission to relaunch; continue waiting on
   the existing run. Confirm completion (`exit=<code>`) before interpreting
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
5. Reuse `-C` for relaunches with the same architecture, compiler and build
   environment. After changing those, use a separate config within the same
   investigation directory with a fresh workspace and build output. Keep
   artifacts out of source commits; do not delete unrelated build state.

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
- Fix verification: if testing a candidate fix needs a tree other than the
  given worktree, do not create one. Report the reproduction, describe the
  fix, and request a decision (apply in the existing worktree, an approved
  scratch worktree, or skip).

## Report

State the goal/assertion, test path, exact commands and environment, result or
reproduction rate, and artifact paths. List job conditions matched and not
matched, and any conditions the test imposed. Include decisive failure output.
If root causing was requested, give the provenance evidence and proposed
resolution. Always state what remains unverified; a green test alone is not
proof.
