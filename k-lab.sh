#!/usr/bin/env bash

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	echo "ERROR: source ${BASH_SOURCE[0]} to load the k-lab wrapper and completion" >&2
	exit 1
fi

THIS_DIR=$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")
# shellcheck disable=SC1091
if ! source "$THIS_DIR/bin/env.sh"; then
	return 1
fi
if ! require_ktest; then
	return 1
fi
if ! require_vng; then
	return 1
fi

usage() {
	echo "usage: kt [-C] [-D name=value] [-n] [-y] [test]"
	echo
	echo "options:"
	echo "  -C              set BUILD_NOCLEAN=1"
	echo "  -D name=value   pass through to ktest.pl as -D name=value or -D name:=value"
	echo "  -n              print resolved test options and exit"
	echo "  -y              non-interactive: auto-confirm prompts, detach ktest.pl's stdin"
	echo "  -h              show this help"
	echo
	echo "run kt from within a Linux kernel worktree."
	echo "with no test argument, kt runs $THIS_DIR/include/defaults.conf."
	echo "test names support Bash tab completion from tests/ and TEST_DIRS."
}

_kt_test_roots() {
	local extra root
	local -a roots=("$THIS_DIR/tests")

	extra=$(read_setup_var TEST_DIRS || true)
	if [[ -n $extra ]]; then
		local IFS=:
		local -a extra_roots=()
		read -r -a extra_roots <<<"$extra"
		for root in "${extra_roots[@]}"; do
			[[ -n $root ]] || continue
			if [[ $root != /* ]]; then
				root=$(realpath -m -- "$THIS_DIR/$root")
			else
				root=$(realpath -m -- "$root")
			fi
			roots+=("$root")
		done
	fi

	printf '%s\n' "${roots[@]}"
}

_kt_resolve_test_path() {
	local file_path=$1
	local root

	if [[ $file_path = /* ]]; then
		printf '%s\n' "$file_path"
		return 0
	fi

	while read -r root; do
		if [[ -e $root/$file_path ]]; then
			printf '%s\n' "$root/$file_path"
			return 0
		fi
	done < <(_kt_test_roots)

	printf '%s\n' "$THIS_DIR/tests/$file_path"
}

_kt_completion() {
	local cur=$2
	local root file full_path
	local -A seen=()
	COMPREPLY=()

	while read -r root; do
		[[ -d $root ]] || continue
		while IFS= read -r file; do
			[[ -n $file ]] || continue
			full_path=$root/$file
			if [[ -f $full_path && $file == *.conf ]]; then
				continue
			fi
			if [[ -n ${seen[$file]-} ]]; then
				continue
			fi
			seen[$file]=1
			if [[ -d $full_path ]]; then
				file=$file/
			fi
			COMPREPLY+=("$file")
		done < <(cd "$root" && compgen -f -- "$cur")
	done < <(_kt_test_roots)
}

_kt_vng_ports_from_dry_run() {
	sed -n 's/.* VNG_PORT=\([0-9][0-9]*\)\( \|$\).*/\1/p' | sort -u
}

_kt_vng_port_in_use() {
	local port=$1
	local re

	re="^(.*python[^ ]* )?[^ ]*/vng .* --ssh ${port}( |$)"
	re+="|^(.*python[^ ]* )?[^ ]*/virtme-run .* --port ${port}( |$)"
	re+="|^[^ ]*/qemu-system-[^ ]* .*guest-cid=${port}([ ,]|$)"

	pgrep -f -- "$re" >/dev/null
}

_kt_tcp_port_in_use() {
	local port=$1
	local port_hex

	printf -v port_hex '%04X' "$port"

	grep -Eiq "^[[:space:]]*[0-9]+: [[:xdigit:]]+:${port_hex} " /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

_kt_dry_run_value() {
	local key=$1
	sed -n "s/^${key} = //p" | head -n 1
}

# Extract a k-lab env var's resolved value from the "SETENV = env ..." line of
# ktest.pl --dry-run output (read on stdin). Needed for ROOT_DISK, CHROOT, and
# ARCH: these are parse-time ":=" config variables, so ktest.pl never emits a
# bare "KEY = ..." option line for them (unlike CHROOT_BUILD, a real option).
# Their resolved values only ever surface inside SETENV/PRE_KTEST, where
# include/*.conf appends them via "ENV := ${ENV} KEY=...". Handles both the
# KEY="quoted value" and KEY=bareword forms; prints the first match.
_kt_setenv_value() {
	local key=$1
	local line
	line=$(sed -n 's/^SETENV = //p' | head -n 1)
	[[ -n $line ]] || return 0
	if [[ $line =~ (^|[[:space:]])${key}=\"([^\"]*)\" ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
	elif [[ $line =~ (^|[[:space:]])${key}=([^[:space:]\"]*) ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
	fi
}

_kt_normalize_root_disk_value() {
	local root_disk=${1-}

	case "$root_disk" in
	"" | 0)
		printf '%s\n' ""
		;;
	*)
		printf '%s\n' "$root_disk"
		;;
	esac
}

_kt_preflight_root_disk() {
	local root_disk=$1

	[[ -n $root_disk ]] || return 0

	if [[ ! -f $root_disk ]]; then
		echo "ERROR: ROOT_DISK must be a disk image file (passed to virtme-ng's --root-disk): $root_disk" >&2
		return 1
	fi
	if [[ ! -r $root_disk ]]; then
		echo "ERROR: ROOT_DISK must be readable by $(id -un): $root_disk" >&2
		return 1
	fi
}

# Fail fast (before any expensive build) if CHROOT_BUILD=1 but CHROOT does
# not resolve to a usable chroot target.
_kt_preflight_chroot() {
	local chroot_build=$1
	local chroot_dir=$2

	[[ $chroot_build == 1 ]] || return 0

	if [[ -z $chroot_dir ]]; then
		echo "ERROR: CHROOT_BUILD=1 requires CHROOT to be set to a directory" >&2
		return 1
	fi

	[[ -d $chroot_dir ]]
}

_kt_confirm() {
	local info=$1
	local prompt=$2
	local reply

	echo "$info" >&2
	printf '%s' "$prompt" >&2
	if ! IFS= read -r reply; then
		echo >&2
		return 1
	fi

	case $reply in
	"" | y | Y | yes | YES | Yes)
		return 0
		;;
	*)
		echo "Aborted." >&2
		return 1
		;;
	esac
}

# Ask what to do when BUILD_TYPE is oldconfig and OUTPUT_DIR/.config exists.
# Returns 0 to continue, 1 to wipe, 2 to abort.
_kt_preflight_oldconfig() {
	local output_dir=$1
	local reply

	printf '%s\n' \
		"INFO: BUILD_TYPE is oldconfig and ${output_dir}/.config" \
		"      already exists. Reusing a stale config may silently" \
		"      disable features required by this test." >&2
	printf 'Continue [Y], wipe and rebuild from defconfig [w], or abort [n]? ' >&2
	if ! IFS= read -r reply; then
		echo >&2
		return 2
	fi
	case $reply in
	"" | y | Y | yes | YES | Yes)	return 0 ;;
	w | W)				return 1 ;;
	*)	echo "Aborted." >&2;	return 2 ;;
	esac
}

# Extract the value of "-D <name>:=<value>" from a kargs-style array (as
# built by kt's getopts loop). Prints the last match, or nothing.
_kt_kargs_override() {
	local name=$1
	shift
	local val="" prev="" arg

	for arg in "$@"; do
		if [[ $prev == "-D" && $arg == "$name":=* ]]; then
			val=${arg#"$name":=}
		fi
		prev=$arg
	done

	printf '%s\n' "$val"
}

# Derive a stable per-test id from the resolved config path plus any
# ROOT_DISK/ARCH overrides (these affect file composition, so different
# combinations must not share a TMP_DIR). Deterministic: reruns of the same
# test with the same overrides reuse the same id.
_kt_compute_klab_id() {
	local file_path=$1
	shift
	local root_disk arch hash sub name

	root_disk=$(_kt_kargs_override ROOT_DISK "$@")
	arch=$(_kt_kargs_override ARCH "$@")

	hash=$(printf '%s' "$file_path|$root_disk|$arch" | sha256sum | cut -c1-8)

	case $file_path in
	"$THIS_DIR"/tests/*) sub=${file_path#"$THIS_DIR"/tests/} ;;
	"$THIS_DIR"/*) sub=${file_path#"$THIS_DIR"/} ;;
	*) sub=$file_path ;;
	esac
	name=$(printf '%s' "$sub" | tr -c 'A-Za-z0-9_.-' '_')

	printf '%s\n' "${name}-${hash}"
}

# Find a free VNG_PORT in the range, skipping anything already in use
# by a running vng/qemu instance or bound on the host.
_kt_pick_free_port() {
	local port

	for ((port = 23000; port < 24000; port++)); do
		if ! _kt_vng_port_in_use "$port" && ! _kt_tcp_port_in_use "$port"; then
			printf '%s\n' "$port"
			return 0
		fi
	done

	return 1
}

kt() {
	local OPTIND opt
	local kargs=()
	local compile_commands_set=0
	local dry_run=0
	local noninteractive=0

	if ! require_ktest; then
		return 1
	fi
	if ! require_vng; then
		return 1
	fi

	while getopts ":CD:hny" opt; do
		case "$opt" in
		C) kargs+=("-D" "BUILD_NOCLEAN=1") ;;
		D)
			case "$OPTARG" in
			COMPILE_COMMANDS=* | COMPILE_COMMANDS:=*)
				compile_commands_set=1
				;;
			ROOT_DISK=* | ARCH=* | VNG_PORT=*)
				echo "ERROR: use -D ${OPTARG%%=*}:=${OPTARG#*=} for file-scoped overrides" >&2
				return 2
				;;
			esac
			kargs+=("-D" "$OPTARG")
			;;
		n) dry_run=1 ;;
		y) noninteractive=1 ;;
		h)
			usage
			return 0
			;;
		:)
			echo "ERROR: -$OPTARG requires an argument" >&2
			usage >&2
			return 2
			;;
		\?)
			echo "ERROR: unknown option -$OPTARG" >&2
			usage >&2
			return 2
			;;
		esac
	done
	shift "$((OPTIND - 1))"

	if ((dry_run)); then
		kargs+=("--dry-run")
	fi

	local file_path
	if (($# == 0)); then
		if ((compile_commands_set == 0)); then
			kargs+=("-D" "COMPILE_COMMANDS:=1")
		fi
		file_path="$THIS_DIR/include/defaults.conf"
	else
		file_path=$(_kt_resolve_test_path "$1")
	fi
	if [[ ! -e $file_path ]]; then
		echo "ERROR: missing config: $file_path" >&2
		return 1
	fi

	local klab_id
	klab_id=$(_kt_compute_klab_id "$file_path" "${kargs[@]}")
	kargs+=("-D" "KLAB_ID:=$klab_id")

	if [[ -z $(_kt_kargs_override VNG_PORT "${kargs[@]}") ]]; then
		local free_port
		if ! free_port=$(_kt_pick_free_port); then
			echo "ERROR: no free VNG_PORT found in the range 23000-23999" >&2
			return 1
		fi
		kargs+=("-D" "VNG_PORT:=$free_port")
	fi

	if ((dry_run)); then
		command "$KTEST_PL" "${kargs[@]}" "$file_path"
		return $?
	fi

	local dry_run_output
	if ! dry_run_output=$(command "$KTEST_PL" "${kargs[@]}" --dry-run "$file_path" </dev/null 2>&1); then
		printf '%s\n' "$dry_run_output" >&2
		return 1
	fi

	local tmp_dir
	tmp_dir=$(printf '%s\n' "$dry_run_output" | sed -n 's/^TMP_DIR = //p' | head -n 1)
	if [[ -z $tmp_dir ]]; then
		echo "ERROR: failed to resolve TMP_DIR from ktest.pl --dry-run" >&2
		printf '%s\n' "$dry_run_output" >&2
		return 1
	fi

	local vng_port
	while read -r vng_port; do
		[[ -n $vng_port ]] || continue
		if _kt_vng_port_in_use "$vng_port" || _kt_tcp_port_in_use "$vng_port"; then
			echo "ERROR: VNG_PORT is already in use: $vng_port" >&2
			return 1
		fi
	done < <(printf '%s\n' "$dry_run_output" | _kt_vng_ports_from_dry_run)

	local root_disk arch chroot_build chroot_dir
	local summary_parts=()
	root_disk=$(_kt_normalize_root_disk_value "$(printf '%s\n' "$dry_run_output" | _kt_setenv_value ROOT_DISK)")
	arch=$(printf '%s\n' "$dry_run_output" | _kt_setenv_value ARCH)
	if [[ -n $root_disk ]]; then
		_kt_preflight_root_disk "$root_disk" || return 1
	fi

	# CHROOT_BUILD is a real ktest.pl option ("="), so read it as an option
	# line; CHROOT is a ":=" variable, so read its value from SETENV instead.
	chroot_build=$(printf '%s\n' "$dry_run_output" | _kt_dry_run_value CHROOT_BUILD)
	chroot_dir=$(printf '%s\n' "$dry_run_output" | _kt_setenv_value CHROOT)
	if [[ ${chroot_build:-0} == 1 ]]; then
		_kt_preflight_chroot "$chroot_build" "$chroot_dir" || return 1
	fi

	if [[ -n $root_disk ]]; then
		summary_parts+=("ROOT_DISK=$root_disk")
		if [[ -n $arch ]]; then
			summary_parts+=("ARCH=$arch")
		fi
	fi
	if [[ ${chroot_build:-0} == 1 ]]; then
		summary_parts+=("CHROOT_BUILD=1" "CHROOT=$chroot_dir")
	fi
	if [[ ${#summary_parts[@]} -gt 0 ]]; then
		local IFS=', '
		if ((noninteractive)); then
			echo "INFO: privileged path configured: ${summary_parts[*]} (auto-confirmed, -y)" >&2
		else
			_kt_confirm \
				"INFO: privileged path configured: ${summary_parts[*]}" \
				'Do you want to continue? [Y/n] ' || return 1
		fi
	fi

	local output_dir
	output_dir=$(printf '%s\n' "$dry_run_output" | _kt_dry_run_value OUTPUT_DIR)
	if [[ -n $output_dir && -f $output_dir/.config ]]; then
		local default_bt needs_prompt max_n bt_overrides
		default_bt=$(printf '%s\n' "$dry_run_output" | _kt_dry_run_value BUILD_TYPE)
		needs_prompt=0
		# Any explicit per-test [N] override that IS oldconfig (or empty,
		# which makes ktest.pl fall back to its built-in default)?
		if printf '%s\n' "$dry_run_output" |
		       grep -qE '^BUILD_TYPE\[[0-9]+\] = (oldconfig)?$'; then
			needs_prompt=1
		fi
		# Default is oldconfig and at least one test has no explicit
		# BUILD_TYPE override (so the default applies to it)?
		# Note: only checks OUTPUT_DIR at the start of the run; does not
		# catch a .config produced by an earlier test in the same run.
		if [[ -z $default_bt || $default_bt == oldconfig ]]; then
			max_n=$(printf '%s\n' "$dry_run_output" |
			    grep -oP '\[\K[0-9]+(?=\] = )' | sort -n | tail -1)
			bt_overrides=$(printf '%s\n' "$dry_run_output" |
			    grep -cE '^BUILD_TYPE\[[0-9]+\] = ')
			if [[ -z $max_n || $bt_overrides -lt $max_n ]]; then
				needs_prompt=1
			fi
		fi
		if ((needs_prompt)); then
			if ((noninteractive)); then
				echo "INFO: BUILD_TYPE is oldconfig and ${output_dir}/.config already exists; continuing (auto-confirmed, -y)" >&2
			else
				_kt_preflight_oldconfig "$output_dir"
				case $? in
				0) ;;
				1) rm -rf "$output_dir"
				   kargs+=("-D" "BUILD_TYPE=defconfig") ;;
				*) return 1 ;;
				esac
			fi
		fi
	fi

	(
		local holder_pid lock_file pid

		holder_pid=${BASHPID:-$$}
		lock_file="${tmp_dir%%/}.lock"

		if ! (
			set -o noclobber
			printf '%s\n' "$holder_pid" >"$lock_file"
		) 2>/dev/null; then
			if [[ ! -e $lock_file ]]; then
				echo "ERROR: failed to create lock file: $lock_file" >&2
				exit 1
			fi

			if [[ -f $lock_file ]]; then
				pid=$(<"$lock_file")
				if [[ $pid =~ ^[0-9]+$ ]]; then
					if ! kill -0 "$pid" 2>/dev/null; then
						rm -f "$lock_file"
					fi
				fi
			fi

			if ! (
				set -o noclobber
				printf '%s\n' "$holder_pid" >"$lock_file"
			) 2>/dev/null; then
				if [[ ! -e $lock_file ]]; then
					echo "ERROR: failed to create lock file: $lock_file" >&2
					exit 1
				fi

				echo "ERROR: $tmp_dir is in use" >&2
				exit 1
			fi
		fi

		trap 'rm -f "$lock_file"' EXIT

		if ((noninteractive)); then
			# Never-written-to FIFO, shared across runs: keeps ktest.pl's stdin
			# open but never ready, so select() blocks instead of busy-spinning
			# on /dev/null (README, "Why not `yes | kt`").
			local stdin_fifo="$THIS_DIR/tmp/.kt-blackhole"
			[[ -p $stdin_fifo ]] || mkfifo "$stdin_fifo" 2>/dev/null
			command "$KTEST_PL" "${kargs[@]}" "$file_path" <>"$stdin_fifo"
		else
			command "$KTEST_PL" "${kargs[@]}" "$file_path"
		fi
	)
}

complete -o nospace -F _kt_completion kt
