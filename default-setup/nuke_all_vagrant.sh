#!/usr/bin/env bash
#
# vagrant_libvirt_cleanup.sh
#
# Strict, project-scoped cleanup for Vagrant + libvirt.
# Default is DRY RUN. Use --force to actually delete.
#
# Usage:
#   ./vagrant_libvirt_cleanup.sh
#   ./vagrant_libvirt_cleanup.sh --force
#   ./vagrant_libvirt_cleanup.sh --pool default
#   ./vagrant_libvirt_cleanup.sh --uri qemu:///system
#   ./vagrant_libvirt_cleanup.sh --quiet
#
# This script ONLY deletes:
# - libvirt domains whose name starts with "<project_dirname>_"
# - libvirt volumes in <pool> whose name starts with "<project_dirname>_"
#
# It will refuse to run if no Vagrantfile is present.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"

FORCE=false
QUIET=false
LIBVIRT_URI="qemu:///system"
POOL_NAME="default"
LOCKDIR="${TMPDIR:-/tmp}/${SCRIPT_NAME}.lockdir"

print_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --force            actually delete; without this it is a dry run
  --quiet            suppress normal output
  --uri URI          libvirt connection URI (e.g. qemu:///system)
  --pool NAME        storage pool name (default: ${POOL_NAME})
  --help             show this help
EOF
}

log() {
  if [[ "$QUIET" == false ]]; then
    echo "$@"
  fi
}

die() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command '$1' not found"
}

virsh_cmd() {
  if [[ -n "$LIBVIRT_URI" ]]; then
    virsh -c "$LIBVIRT_URI" "$@"
  else
    virsh "$@"
  fi
}

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
    return 0
  fi
  die "another instance is running"
}

run_or_print() {
  local desc="$1"
  shift
  if [[ "$FORCE" == false ]]; then
    log "DRY-RUN: $desc"
    return 0
  fi
  "$@"
}

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
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

require_cmd vagrant
require_cmd virsh

# Must be run from a Vagrant project directory
[[ -f "Vagrantfile" ]] || die "no Vagrantfile found in current directory; cd into the project directory first"

acquire_lock

PROJECT_NAME="$(basename "$(pwd)")"
PROJECT_PREFIX="${PROJECT_NAME}_"

log "Project directory: $(pwd)"
log "Project prefix:    ${PROJECT_PREFIX}"
log "Libvirt pool:      ${POOL_NAME}"
log "Libvirt URI:       ${LIBVIRT_URI}"
if [[ "$FORCE" == false ]]; then
  log "Mode:              DRY RUN (use --force to delete)"
else
  log "Mode:              DESTRUCTIVE (--force enabled)"
fi

# --------------------
# Step 1: Ask vagrant to destroy what it knows about (best effort)
# --------------------
log ""
log "Step 1: vagrant destroy -f (best effort, project-local)"
if [[ "$FORCE" == false ]]; then
  log "DRY-RUN: vagrant destroy -f"
else
  # Do not fail the script if vagrant has no state or provider errors
  vagrant destroy -f || true
fi

# --------------------
# Step 2: Libvirt domain cleanup (project-prefix only)
# --------------------
log ""
log "Step 2: libvirt domains matching prefix '${PROJECT_PREFIX}'"

domains="$(virsh_cmd list --all --name 2>/dev/null || true)"
matched_domains=()

if [[ -n "$domains" ]]; then
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if [[ "$d" == "${PROJECT_PREFIX}"* ]]; then
      matched_domains+=("$d")
    fi
  done <<< "$domains"
fi

if [[ ${#matched_domains[@]} -eq 0 ]]; then
  log "No matching domains found."
else
  for d in "${matched_domains[@]}"; do
    state="$(virsh_cmd domstate "$d" 2>/dev/null || true)"
    log "Domain: $d (state: $state)"

    # If running, destroy first
    if [[ "${state,,}" == *running* ]]; then
      run_or_print "virsh destroy '$d'" virsh_cmd destroy "$d" >/dev/null 2>&1 || true
    fi

    # Undefine without any broad “remove all storage” unless it is already attached
    # We keep it simple and safe: undefine the domain definition only.
    run_or_print "virsh undefine '$d'" virsh_cmd undefine "$d" >/dev/null 2>&1 || true
  done
fi

# --------------------
# Step 3: Libvirt volume cleanup (project-prefix only)
# --------------------
log ""
log "Step 3: libvirt volumes in pool '${POOL_NAME}' matching prefix '${PROJECT_PREFIX}'"

if ! virsh_cmd pool-info "$POOL_NAME" >/dev/null 2>&1; then
  log "Pool '${POOL_NAME}' not found (skipping volume cleanup)."
else
  vols="$(virsh_cmd vol-list "$POOL_NAME" --name 2>/dev/null || true)"
  matched_vols=()

  if [[ -n "$vols" ]]; then
    while IFS= read -r v; do
      [[ -n "$v" ]] || continue
      if [[ "$v" == "${PROJECT_PREFIX}"* ]]; then
        matched_vols+=("$v")
      fi
    done <<< "$vols"
  fi

  if [[ ${#matched_vols[@]} -eq 0 ]]; then
    log "No matching volumes found."
  else
    for v in "${matched_vols[@]}"; do
      log "Volume: $v"
      run_or_print "virsh vol-delete '$v' --pool '${POOL_NAME}'" \
        virsh_cmd vol-delete "$v" --pool "$POOL_NAME" >/dev/null 2>&1 || true
    done
  fi
fi

# --------------------
# Step 4: Final prune
# --------------------
log ""
log "Step 4: vagrant global-status --prune"
if [[ "$FORCE" == false ]]; then
  log "DRY-RUN: vagrant global-status --prune"
else
  vagrant global-status --prune >/dev/null 2>&1 || true
fi

log ""
log "Done."