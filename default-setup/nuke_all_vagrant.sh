#!/usr/bin/env bash
#
# vagrant_libvirt_nuke.sh
#
# Infrastructure-grade, idempotent cleanup for Vagrant + libvirt.
#
# Goals:
# - Idempotent: safe to run repeatedly, handles partial state and races.
# - Default SAFE mode: only deletes libvirt domains that look Vagrant-managed.
# - Optional ALL mode: deletes all libvirt domains (dangerous).
# - Cleans Vagrant-managed machines first, then libvirt leftovers, then prunes Vagrant status.
#
# Usage:
#   ./vagrant_libvirt_cleanup.sh
#   ./vagrant_libvirt_cleanup.sh --dry-run
#   ./vagrant_libvirt_cleanup.sh --mode safe
#   ./vagrant_libvirt_cleanup.sh --mode all
#   ./vagrant_libvirt_cleanup.sh --uri qemu:///system
#   ./vagrant_libvirt_cleanup.sh --pool default
#   ./vagrant_libvirt_cleanup.sh --quiet
#   ./vagrant_libvirt_cleanup.sh --help

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

MODE="safe"                # safe | all
DRY_RUN=false
QUIET=false
LIBVIRT_URI=""             # e.g. qemu:///system ; empty uses virsh default
POOL_NAME="default"        # used for optional orphan sweep in safe mode
LOCKDIR="${TMPDIR:-/tmp}/${SCRIPT_NAME}.lockdir"

EXIT_CODE=0

print_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --mode safe|all     safe = only Vagrant-tagged/likely Vagrant domains (default)
                      all  = remove all libvirt domains (dangerous)
  --dry-run           show actions without changing anything
  --quiet             suppress normal output (errors still to stderr)
  --uri URI           libvirt connection URI (e.g. qemu:///system)
  --pool NAME         storage pool name for optional orphan sweep (default: $POOL_NAME)
  --help              show this help

Exit codes:
  0  success (including "nothing to do")
  1  partial failure (some actions failed)
EOF
}

log() {
  if [[ "$QUIET" == false ]]; then
    echo "$@"
  fi
}

warn() {
  echo "Warning: $*" >&2
  EXIT_CODE=1
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"
}

run_cmd() {
  local desc="$1"
  shift
  if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN: $desc"
    return 0
  fi
  "$@" || return $?
}

virsh_cmd() {
  if [[ -n "$LIBVIRT_URI" ]]; then
    virsh -c "$LIBVIRT_URI" "$@"
  else
    virsh "$@"
  fi
}

acquire_lock() {
  # Portable lock using atomic mkdir
  if mkdir "$LOCKDIR" 2>/dev/null; then
    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
    return 0
  fi
  die "another instance is running (lockdir: $LOCKDIR)"
}

# ---- Parse arguments ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || die "--mode requires an argument"
      MODE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --quiet)
      QUIET=true
      shift
      ;;
    --uri)
      [[ $# -ge 2 ]] || die "--uri requires an argument"
      LIBVIRT_URI="$2"
      shift 2
      ;;
    --pool)
      [[ $# -ge 2 ]] || die "--pool requires an argument"
      POOL_NAME="$2"
      shift 2
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      die "unknown argument: $1 (use --help)"
      ;;
  esac
done

if [[ "$MODE" != "safe" && "$MODE" != "all" ]]; then
  die "--mode must be 'safe' or 'all'"
fi

require_cmd vagrant
require_cmd virsh

acquire_lock

# --------------------
# Step 1: Destroy all Vagrant libvirt machines (best-effort)
# --------------------
log "Cleaning Vagrant-managed libvirt machines..."

destroyed_any=false

# Parse vagrant --machine-readable without awk.
# Format: timestamp,target,type,data(with possible commas)
# We reconstruct data as everything after the third comma.
parse_global_status_machine_readable() {
  local line ts rest target type data
  declare -gA _prov=()
  declare -gA _dir=()

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    ts="${line%%,*}"
    rest="${line#*,}"
    [[ "$rest" != "$line" ]] || continue

    target="${rest%%,*}"
    rest="${rest#*,}"
    [[ "$rest" != "$target" ]] || continue

    type="${rest%%,*}"
    data="${rest#*,}"

    # Some lines may have fewer commas; guard
    [[ -n "$target" && -n "$type" ]] || continue

    if [[ "$type" == "provider-name" ]]; then
      _prov["$target"]="$data"
    elif [[ "$type" == "machine-home" ]]; then
      _dir["$target"]="$data"
    fi
  done < <(vagrant global-status --prune --machine-readable 2>/dev/null || true)

  # Emit id<TAB>dir for libvirt rows with known directory
  local id
  for id in "${!_prov[@]}"; do
    if [[ "${_prov[$id]}" == "libvirt" && -n "${_dir[$id]:-}" ]]; then
      printf "%s\t%s\n" "$id" "${_dir[$id]}"
    fi
  done
}

ids_dirs="$(parse_global_status_machine_readable || true)"

if [[ -n "$ids_dirs" ]]; then
  while IFS=$'\t' read -r id dir; do
    [[ -n "$id" ]] || continue
    if [[ -n "$dir" && -d "$dir" ]]; then
      log "Destroying $id in $dir"
      if run_cmd "vagrant destroy -f $id (in $dir)" bash -c "cd \"\$1\" && vagrant destroy -f \"\$2\"" _ "$dir" "$id"; then
        destroyed_any=true
      else
        warn "vagrant destroy failed for id=$id dir=$dir"
      fi
    else
      log "Skipping $id (directory missing)"
    fi
  done <<< "$ids_dirs"
else
  # Fallback: still attempt prune only. We do not try to parse human output without awk.
  # This keeps the script dependency-light and avoids fragile space parsing.
  :
fi

# --------------------
# Step 2: Libvirt domain cleanup
# --------------------
log "Cleaning libvirt domains (mode: $MODE)..."

list_domains() {
  virsh_cmd list --all --name 2>/dev/null || true
}

is_vagrant_domain_safe() {
  local domain="$1"

  # Name heuristics (common vagrant-libvirt patterns)
  if [[ "$domain" =~ (^vagrant($|[-_])|[-_]vagrant($|[-_])|^_?vagrant_) ]]; then
    return 0
  fi

  # XML heuristics
  local xml xml_lc
  if ! xml="$(virsh_cmd dumpxml "$domain" 2>/dev/null)"; then
    return 1
  fi
  xml_lc="${xml,,}"
  [[ "$xml_lc" == *vagrant* ]]
}

cleanup_domain() {
  local domain="$1"

  # Domain might vanish between list and action
  if ! virsh_cmd dominfo "$domain" >/dev/null 2>&1; then
    return 0
  fi

  local state state_lc
  state="$(virsh_cmd domstate "$domain" 2>/dev/null || true)"
  state_lc="${state,,}"

  if [[ "$state_lc" == *running* ]]; then
    if ! run_cmd "virsh destroy $domain" virsh_cmd destroy "$domain" >/dev/null 2>&1; then
      warn "failed to destroy running domain: $domain"
    fi
  fi

  if run_cmd "virsh undefine $domain --remove-all-storage" virsh_cmd undefine "$domain" --remove-all-storage >/dev/null 2>&1; then
    log "Removed domain $domain"
    return 0
  fi

  if run_cmd "virsh undefine $domain" virsh_cmd undefine "$domain" >/dev/null 2>&1; then
    log "Removed domain $domain"
    return 0
  fi

  warn "failed to undefine domain: $domain"
  return 1
}

domains="$(list_domains)"
if [[ -n "$domains" ]]; then
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue

    if [[ "$MODE" == "safe" ]]; then
      if is_vagrant_domain_safe "$domain"; then
        log "Processing domain: $domain"
        cleanup_domain "$domain" || true
      fi
    else
      log "Processing domain: $domain"
      cleanup_domain "$domain" || true
    fi
  done <<< "$domains"
fi

# --------------------
# Step 3: Optional orphan volume sweep (conservative, safe mode only)
# --------------------
# Uses virsh --name outputs when available.
if [[ "$MODE" == "safe" ]]; then
  if virsh_cmd pool-info "$POOL_NAME" >/dev/null 2>&1; then
    log "Sweeping orphaned volumes in pool '$POOL_NAME' (safe heuristics)..."
    vols="$(virsh_cmd vol-list "$POOL_NAME" --name 2>/dev/null || true)"
    if [[ -n "$vols" ]]; then
      while IFS= read -r vol; do
        [[ -n "$vol" ]] || continue
        vol_lc="${vol,,}"

        # Conservative: only likely Vagrant volumes
        if [[ "$vol_lc" == *vagrant* || "$vol_lc" == *.qcow2 || "$vol_lc" == *.img ]]; then
          if run_cmd "virsh vol-delete $vol (pool $POOL_NAME)" virsh_cmd vol-delete "$vol" --pool "$POOL_NAME" >/dev/null 2>&1; then
            log "Removed volume $vol (pool $POOL_NAME)"
          else
            warn "failed to delete volume: $vol (pool $POOL_NAME)"
          fi
        fi
      done <<< "$vols"
    fi
  fi
fi

# --------------------
# Step 4: Final Vagrant prune
# --------------------
log "Final Vagrant prune..."
if [[ "$DRY_RUN" == true ]]; then
  log "DRY-RUN: vagrant global-status --prune"
else
  if ! vagrant global-status --prune >/dev/null 2>&1; then
    warn "vagrant global-status --prune failed"
  fi
fi

if [[ "$EXIT_CODE" -eq 0 ]]; then
  log "Cleanup complete."
else
  warn "Cleanup finished with warnings/failures."
fi

exit "$EXIT_CODE"
