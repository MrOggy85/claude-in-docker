#!/usr/bin/env bash
#
# Emit `docker run` resource-limit tokens for the session container, one per
# line, so a runaway process is killed inside its OWN cgroup instead of leaving
# the host's OOM killer to pick a victim by size — which is how an unrelated
# container ends up dead. See docs/resource-limits.md.
#
#   --memory=<v> --memory-swap=<v> --cpus=<v> --pids-limit=<n>
#
# Defaults are derived from the DOCKER HOST, read once via `docker info`: on
# Docker Desktop that is the VM's slice, not the Mac's RAM, and the VM is what
# the limit has to fit inside. Without that reading the memory and cpu defaults
# are skipped (explicit values are still honoured) rather than guessed.
#
#   memory      25% of host RAM, floor 2g   — ~4 concurrent sessions before the
#                                             host itself is oversubscribed
#   memory-swap equal to memory             — i.e. NO swap: a capped container
#                                             that swaps drags the whole host
#                                             into thrash instead of dying
#   cpus        host CPUs - 2               — leaves the host responsive; not set
#                                             at all on a 1-2 core host
#   pids        2048                        — contains a fork bomb / `make -j`
#
# Each is overridable, and each takes 0 / off / none / unlimited to switch that
# one limit off. A malformed value is fatal: silently falling back to "no limit"
# is the exact failure this script exists to prevent.
#
# Inputs (environment):
#   CLAUDE_MEMORY       e.g. 6g, 4096m, unlimited
#   CLAUDE_MEMORY_SWAP  memory+swap total; must be >= CLAUDE_MEMORY
#   CLAUDE_CPUS         e.g. 8, 1.5, unlimited
#   CLAUDE_PIDS_LIMIT   e.g. 2048, unlimited
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Messages go to stderr; stdout is the token stream. See scripts/colors.sh.
# shellcheck source=colors.sh disable=SC1091
source "${SCRIPT_DIR}/colors.sh"
color_init 2

# "off" spellings, shared by all four knobs. Listed rather than lower-cased:
# macOS ships bash 3.2, which has no ${var,,}.
is_off() {  # <value>
  case "$1" in
    0|-1|off|no|none|false|unlimited|OFF|NO|NONE|FALSE|UNLIMITED) return 0 ;;
    *) return 1 ;;
  esac
}

# Docker size string -> bytes. Empty on a malformed value (the caller reports).
to_bytes() {  # <value>
  local v="$1" n="${1%[bkmgBKMG]}" suffix="${1: -1}"
  [[ "$n" =~ ^[0-9]+$ ]] || return 0
  case "$suffix" in
    b|B) printf '%s' "$n" ;;
    k|K) printf '%s' "$(( n * 1024 ))" ;;
    m|M) printf '%s' "$(( n * 1024 * 1024 ))" ;;
    g|G) printf '%s' "$(( n * 1024 * 1024 * 1024 ))" ;;
    *)   [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" ;;   # unsuffixed = bytes
  esac
}

die() {  # <var> <value> <hint...>
  fail "$1=$2 is not a valid value" "${@:3}"
  exit 1
}

# The daemon's own view: host RAM/CPUs on Linux, the VM's on Docker Desktop.
# Non-fatal — run.sh has already used docker by now, so a failure here means
# something odd, not a broken run; the defaults are skipped and said so.
HOST_MEM_BYTES=""
HOST_CPUS=""
if _info="$(docker info --format '{{.MemTotal}} {{.NCPU}}' 2>/dev/null)"; then
  read -r _mem _cpus <<< "${_info}"
  [[ "${_mem:-}"  =~ ^[0-9]+$ ]] && HOST_MEM_BYTES="${_mem}"
  [[ "${_cpus:-}" =~ ^[0-9]+$ ]] && HOST_CPUS="${_cpus}"
fi

# ---- memory ---------------------------------------------------------------

MEMORY=""
# Set only when there is no limit BECAUSE the host reading failed — an explicit
# opt-out is a decision and must not be warned about.
MEM_UNDERIVED=""
if [[ -n "${CLAUDE_MEMORY:-}" ]]; then
  if ! is_off "${CLAUDE_MEMORY}"; then
    MEMORY="${CLAUDE_MEMORY}"
    _bytes="$(to_bytes "${MEMORY}")"
    [[ -n "${_bytes}" ]] || die CLAUDE_MEMORY "${MEMORY}" \
      "Use a number with an optional b/k/m/g suffix (e.g. 6g), or 'unlimited'."
    # Docker's own floor; below it `docker run` fails with a less clear message.
    (( _bytes >= 6291456 )) || die CLAUDE_MEMORY "${MEMORY}" "The minimum Docker accepts is 6m."
  fi
elif [[ -n "${HOST_MEM_BYTES}" ]]; then
  # Whole GiB, rounded down, so the value stays legible; floor 2g.
  _quarter_gb=$(( HOST_MEM_BYTES / 4 / 1024 / 1024 / 1024 ))
  (( _quarter_gb < 2 )) && _quarter_gb=2
  MEMORY="${_quarter_gb}g"
else
  MEM_UNDERIVED=1
fi

# Swap defaults to the memory limit, which is how Docker spells "no swap".
SWAP=""
if [[ -n "${CLAUDE_MEMORY_SWAP:-}" ]]; then
  if ! is_off "${CLAUDE_MEMORY_SWAP}"; then
    [[ -n "${MEMORY}" ]] || die CLAUDE_MEMORY_SWAP "${CLAUDE_MEMORY_SWAP}" \
      "A swap total means nothing without a memory limit — set CLAUDE_MEMORY too."
    SWAP="${CLAUDE_MEMORY_SWAP}"
    _swap_bytes="$(to_bytes "${SWAP}")"
    [[ -n "${_swap_bytes}" ]] || die CLAUDE_MEMORY_SWAP "${SWAP}" \
      "Use a number with an optional b/k/m/g suffix (e.g. 8g), or 'unlimited'."
    # Docker rejects a total below the memory limit; catch it here with the reason.
    (( _swap_bytes >= $(to_bytes "${MEMORY}") )) || die CLAUDE_MEMORY_SWAP "${SWAP}" \
      "It is memory+swap COMBINED, so it cannot be below CLAUDE_MEMORY (${MEMORY})."
  fi
elif [[ -n "${MEMORY}" ]]; then
  SWAP="${MEMORY}"
fi

# ---- cpus -----------------------------------------------------------------

CPUS=""
if [[ -n "${CLAUDE_CPUS:-}" ]]; then
  if ! is_off "${CLAUDE_CPUS}"; then
    CPUS="${CLAUDE_CPUS}"
    [[ "${CPUS}" =~ ^[0-9]+(\.[0-9]+)?$ && ! "${CPUS}" =~ ^0+(\.0+)?$ ]] || die CLAUDE_CPUS "${CPUS}" \
      "Use a positive number of cores (e.g. 8 or 1.5), or 'unlimited'."
  fi
elif [[ -n "${HOST_CPUS}" ]] && (( HOST_CPUS > 2 )); then
  CPUS=$(( HOST_CPUS - 2 ))
fi

# ---- pids -----------------------------------------------------------------

PIDS=""
if [[ -n "${CLAUDE_PIDS_LIMIT:-}" ]]; then
  if ! is_off "${CLAUDE_PIDS_LIMIT}"; then
    PIDS="${CLAUDE_PIDS_LIMIT}"
    # 10# so a padded "0008" is decimal, not an invalid octal literal.
    if ! [[ "${PIDS}" =~ ^[0-9]+$ ]] || (( 10#${PIDS} < 1 )); then
      die CLAUDE_PIDS_LIMIT "${PIDS}" "Use a positive process count (e.g. 2048), or 'unlimited'."
    fi
  fi
else
  PIDS=2048
fi

# ---- emit -----------------------------------------------------------------

SUMMARY=""
add_summary() { SUMMARY="${SUMMARY:+${SUMMARY}, }$1"; }

if [[ -n "${MEMORY}" ]]; then
  printf -- '--memory=%s\n' "${MEMORY}"
  add_summary "memory ${MEMORY}"
fi
if [[ -n "${SWAP}" ]]; then
  printf -- '--memory-swap=%s\n' "${SWAP}"
  if [[ "${SWAP}" == "${MEMORY}" ]]; then add_summary "swap off"
  else                                    add_summary "+swap to ${SWAP}"; fi
fi
if [[ -n "${CPUS}" ]]; then
  printf -- '--cpus=%s\n' "${CPUS}"
  add_summary "cpus ${CPUS}"
fi
if [[ -n "${PIDS}" ]]; then
  printf -- '--pids-limit=%s\n' "${PIDS}"
  add_summary "pids ${PIDS}"
fi

if [[ -z "${SUMMARY}" ]]; then
  warn "no resource limits on this container" \
       "A runaway process can exhaust the host, and the kernel may then kill a" \
       "bystander container instead. See docs/resource-limits.md."
else
  kv "resource limits" "${SUMMARY}"
  if [[ -n "${MEM_UNDERIVED}" ]]; then
    warn "no memory limit on this container" \
         "\`docker info\` did not report the host's RAM, so the default could not" \
         "be derived. Set CLAUDE_MEMORY explicitly. See docs/resource-limits.md."
  fi
fi
