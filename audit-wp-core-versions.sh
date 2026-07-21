#!/usr/bin/env bash
#
# audit-wp-core-versions.sh
#
# Scans every WordPress site you own on Pantheon (via Terminus), reads the
# installed WordPress core version from a chosen environment, and reports the
# sites whose version falls within one or more AFFECTED VERSION RANGES.
# Results are written to a fresh, timestamped output directory, and a prominent
# ALERT is printed at the end if any affected sites were found.
#
# The script hardcodes NOTHING personal: it discovers sites via Terminus scope
# filters (default: sites you own), so anyone authenticated to Terminus can run
# it against their own sites unchanged.
#
# Requirements: bash (3.2+), terminus (>= 3.x), an authenticated Terminus
# session.
#
# Usage:
#   ./audit-wp-core-versions.sh [options]
#
# Options:
#   -r, --ranges <spec>     Comma-separated inclusive ranges "low-high,low-high".
#                           Default: 6.9.0-6.9.4,7.0.0-7.0.1
#   -e, --env <env>         Environment to read the version from (default: dev).
#   -s, --scope <scope>     Which sites to scan (default: me):
#                             me    sites you own                 (--owner=me)
#                             team  sites you're a team member of (--team)
#                             org   sites in your organization(s) (--org)
#                             all   every site accessible to you  (no filter)
#       --org <id>          Organization name/label/UUID to scan. Implies
#                           "--scope org" on its own — no need to also pass -s.
#                           ("-s org" without --org scans all your orgs.)
#   -d, --output <dir>      Parent directory for the report (default: ./reports).
#       --include-frozen    Also scan frozen sites (skipped by default).
#   -j, --jobs <n>          Max parallel version checks (default: 5).
#   -h, --help              Show this help and exit.
#
# Env var equivalents (flags win): AUDIT_RANGES, AUDIT_ENV, AUDIT_SCOPE,
# AUDIT_ORG, AUDIT_OUTPUT, AUDIT_INCLUDE_FROZEN, AUDIT_JOBS.
#
# Exit codes:
#   0  clean run, no affected sites found
#   1  usage / precondition error
#   2  run completed AND at least one affected site was found (the "alert")

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults (overridable by env vars, then by flags)
# ----------------------------------------------------------------------------
RANGES="${AUDIT_RANGES:-6.9.0-6.9.4,7.0.0-7.0.1}"
ENVIRONMENT="${AUDIT_ENV:-dev}"
SCOPE="${AUDIT_SCOPE:-me}"
ORG="${AUDIT_ORG:-all}"
OUTPUT_PARENT="${AUDIT_OUTPUT:-./reports}"
INCLUDE_FROZEN="${AUDIT_INCLUDE_FROZEN:-0}"
JOBS="${AUDIT_JOBS:-5}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }

# Block until fewer than $JOBS background jobs are running (bounded pool).
throttle() { while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.15; done; }

usage() {
  # Print the leading comment block (from line 2 until the first non-comment
  # line), stripping the leading "# ". Robust to the header changing length.
  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
  exit "${1:-0}"
}

# Reduce a raw version string to a comparable numeric-dotted form.
# e.g. "6.8.2-RC1" -> "6.8.2", "6.8" -> "6.8", "Version 6.4" -> "6.4"
sanitize_version() {
  printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//; s/\.$//'
}

# Numeric, dot-aware comparison. Pads missing segments with 0 so "6.8" == "6.8.0"
# (WordPress reports the x.y.0 release simply as "x.y"). Echoes -1 / 0 / 1.
version_cmp() {
  local IFS=. i x y
  local -a A B
  read -ra A <<<"$1"
  read -ra B <<<"$2"
  for i in 0 1 2 3; do
    x=$(( 10#${A[i]:-0} ))
    y=$(( 10#${B[i]:-0} ))
    (( x < y )) && { printf -- '-1'; return; }
    (( x > y )) && { printf -- '1';  return; }
  done
  printf -- '0'
}

# True (0) if version $1 is within the inclusive range [$2, $3].
in_range() {
  [ "$(version_cmp "$2" "$1")" -le 0 ] && [ "$(version_cmp "$1" "$3")" -le 0 ]
}

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--ranges)       RANGES="${2:?--ranges needs a value}"; shift 2 ;;
    -e|--env)          ENVIRONMENT="${2:?--env needs a value}"; shift 2 ;;
    -s|--scope)        SCOPE="${2:?--scope needs a value}"; shift 2 ;;
    --org)             ORG="${2:?--org needs a value}"; SCOPE=org; shift 2 ;;  # implies --scope org
    -d|--output)       OUTPUT_PARENT="${2:?--output needs a value}"; shift 2 ;;
    --include-frozen)  INCLUDE_FROZEN=1; shift ;;
    -j|--jobs)         JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -h|--help)         usage 0 ;;
    *) err "Unknown option: $1"; usage 1 ;;
  esac
done

case "$JOBS" in ''|*[!0-9]*) err "--jobs must be a positive integer"; exit 1 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

# Map scope -> the terminus site:list filter flags. An empty array (scope=all)
# is expanded safely below with the "${arr[@]+...}" idiom for bash 3.2.
case "$SCOPE" in
  me)   SITE_FILTER=(--owner=me) ;;
  team) SITE_FILTER=(--team) ;;
  org)  SITE_FILTER=(--org="$ORG") ;;
  all)  SITE_FILTER=() ;;
  *) err "Invalid --scope '$SCOPE' (expected: me | team | org | all)"; exit 1 ;;
esac

# Parse RANGES spec into parallel arrays.
IFS=',' read -ra RANGE_SPECS <<<"$RANGES"
RANGE_LO=(); RANGE_HI=(); RANGE_LABEL=()
for spec in "${RANGE_SPECS[@]}"; do
  spec="$(printf '%s' "$spec" | tr -d '[:space:]')"
  [ -z "$spec" ] && continue
  lo="${spec%%-*}"; hi="${spec##*-}"
  if [ -z "$lo" ] || [ -z "$hi" ] || [ "$lo" = "$spec" ]; then
    err "Bad range spec '$spec' (expected low-high, e.g. 6.8.0-6.8.5)"; exit 1
  fi
  RANGE_LO+=("$lo"); RANGE_HI+=("$hi"); RANGE_LABEL+=("$lo-$hi")
done
[ "${#RANGE_LO[@]}" -gt 0 ] || { err "No valid ranges parsed from '$RANGES'"; exit 1; }

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
if ! command -v terminus >/dev/null 2>&1; then
  err "terminus is not installed or not on PATH. See https://docs.pantheon.io/terminus"
  exit 1
fi

if ! terminus auth:whoami >/dev/null 2>&1; then
  err "No active Terminus session. Run: terminus auth:login --machine-token=<token>"
  exit 1
fi

# Use --field=email explicitly: some Terminus versions return an empty string
# for `--format=string` on the whoami record.
WHO="$(terminus auth:whoami --field=email 2>/dev/null || true)"
WHO="${WHO:-unknown}"

# ----------------------------------------------------------------------------
# Prepare output directory (the "new directory" per run)
# ----------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTPUT_PARENT%/}/wp-core-audit-${STAMP}"
mkdir -p "$OUTDIR"

MATCHES_CSV="${OUTDIR}/matches.csv"
MATCHES_JSON="${OUTDIR}/matches.json"
SCAN_CSV="${OUTDIR}/scan-full.csv"
SUMMARY="${OUTDIR}/summary.txt"

printf 'site,environment,wp_core_version,matched_range\n' > "$MATCHES_CSV"
printf 'site,environment,framework,frozen,wp_core_version,status\n' > "$SCAN_CSV"

# Human-readable scope label for the logs/summary.
case "$SCOPE" in
  org) SCOPE_LABEL="org (${ORG})" ;;
  *)   SCOPE_LABEL="$SCOPE" ;;
esac

info "Authenticated as: ${WHO}"
info "Affected ranges:  ${RANGE_LABEL[*]}"
info "Environment:      ${ENVIRONMENT}"
info "Scope:            ${SCOPE_LABEL}"
info "Output directory: ${OUTDIR}"
info "Discovering WordPress sites (this can take a minute on large accounts) ..."

# ----------------------------------------------------------------------------
# Discover sites (name, framework, frozen) as CSV, skipping the header.
# Site slugs never contain commas, so naive CSV splitting is safe here.
# ----------------------------------------------------------------------------
SITES_RAW="$(terminus site:list ${SITE_FILTER[@]+"${SITE_FILTER[@]}"} \
  --fields=name,framework,frozen --format=csv 2>/dev/null | tail -n +2)"

if [ -z "$SITES_RAW" ]; then
  err "No sites returned for scope='${SCOPE_LABEL}'. Nothing to scan."
  exit 1
fi

# ----------------------------------------------------------------------------
# Parse + classify into arrays FIRST. This loop reads the site list on stdin
# and contains NO ssh/terminus calls, so nothing can drain the input. (Doing
# the remote calls inside a `while read ... done <<EOF` loop is a trap: terminus
# shells out to ssh, ssh reads stdin, and it eats the rest of the site list --
# the loop then exits after one site. That is why an earlier version came back
# empty.) We scan from the array below instead.
# ----------------------------------------------------------------------------
TOTAL=0; SKIPPED_FROZEN=0; SKIPPED_NONWP=0
SCAN_NAMES=(); SCAN_FW=(); SCAN_FROZEN=()

while IFS=, read -r NAME FRAMEWORK FROZEN _rest; do
  [ -z "$NAME" ] && continue
  TOTAL=$((TOTAL + 1))

  case "$FRAMEWORK" in
    wordpress*) : ;;
    *) SKIPPED_NONWP=$((SKIPPED_NONWP + 1)); continue ;;
  esac

  case "$FROZEN" in
    true|1|True|TRUE)
      if [ "$INCLUDE_FROZEN" != "1" ]; then
        SKIPPED_FROZEN=$((SKIPPED_FROZEN + 1))
        printf '%s,%s,%s,%s,,skipped-frozen\n' \
          "$NAME" "$ENVIRONMENT" "$FRAMEWORK" "$FROZEN" >> "$SCAN_CSV"
        continue
      fi
      ;;
  esac

  SCAN_NAMES+=("$NAME"); SCAN_FW+=("$FRAMEWORK"); SCAN_FROZEN+=("$FROZEN")
done <<EOF
$SITES_RAW
EOF

TO_SCAN=${#SCAN_NAMES[@]}
info "Found ${TOTAL} owned site(s): ${TO_SCAN} to scan, ${SKIPPED_NONWP} non-WordPress, ${SKIPPED_FROZEN} frozen (skipped)."
info ""

# ----------------------------------------------------------------------------
# Scan phase — PARALLEL. Each worker fetches one site's WP core version over
# the network and writes it to its own result file (no shared writers). The
# range logic and all CSV/JSON writes happen in the sequential aggregation pass
# below, in deterministic index order.
# ----------------------------------------------------------------------------
SCAN_WORK="$(mktemp -d)"
trap 'rm -rf "$SCAN_WORK"' EXIT

scan_worker() {
  local idx="$1" name="$2" raw ver
  raw="$(terminus remote:wp "${name}.${ENVIRONMENT}" -- core version </dev/null 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  ver="$(sanitize_version "${raw:-}")"
  printf '%s' "$ver" > "${SCAN_WORK}/${idx}"
  if [ -n "$ver" ]; then
    printf '  [ok] %s.%s -> %s\n' "$name" "$ENVIRONMENT" "$ver" >&2
  else
    printf '  [!!] %s.%s -> no version\n' "$name" "$ENVIRONMENT" >&2
  fi
}

info "Scanning ${TO_SCAN} site(s), up to ${JOBS} in parallel ..."
i=0
while [ "$i" -lt "$TO_SCAN" ]; do
  throttle
  scan_worker "$i" "${SCAN_NAMES[$i]}" &
  i=$((i + 1))
done
wait

# Aggregate results sequentially (deterministic order, single writer).
SCANNED=0; ERRORS=0; MATCHED=0; JSON_ROWS=""
NRANGES=${#RANGE_LO[@]}
i=0
while [ "$i" -lt "$TO_SCAN" ]; do
  NAME="${SCAN_NAMES[$i]}"; FRAMEWORK="${SCAN_FW[$i]}"; FROZEN="${SCAN_FROZEN[$i]}"
  VER="$(cat "${SCAN_WORK}/${i}" 2>/dev/null || true)"
  i=$((i + 1))
  SCANNED=$((SCANNED + 1))

  if [ -z "$VER" ]; then
    ERRORS=$((ERRORS + 1))
    printf '%s,%s,%s,%s,,error-or-no-version\n' \
      "$NAME" "$ENVIRONMENT" "$FRAMEWORK" "$FROZEN" >> "$SCAN_CSV"
    continue
  fi

  printf '%s,%s,%s,%s,%s,ok\n' \
    "$NAME" "$ENVIRONMENT" "$FRAMEWORK" "$FROZEN" "$VER" >> "$SCAN_CSV"

  hit=""
  j=0
  while [ "$j" -lt "$NRANGES" ]; do
    if in_range "$VER" "${RANGE_LO[$j]}" "${RANGE_HI[$j]}"; then
      hit="${RANGE_LABEL[$j]}"; break
    fi
    j=$((j + 1))
  done

  if [ -n "$hit" ]; then
    MATCHED=$((MATCHED + 1))
    printf '%s,%s,%s,%s\n' "$NAME" "$ENVIRONMENT" "$VER" "$hit" >> "$MATCHES_CSV"
    JSON_ROWS="${JSON_ROWS}$(printf '{"site":"%s","environment":"%s","wp_core_version":"%s","matched_range":"%s"}' \
      "$NAME" "$ENVIRONMENT" "$VER" "$hit"),"
  fi
done
rm -rf "$SCAN_WORK"; trap - EXIT

# ----------------------------------------------------------------------------
# Write JSON (built by hand to avoid a jq dependency)
# ----------------------------------------------------------------------------
{
  printf '[\n'
  printf '%s' "${JSON_ROWS%,}" | sed 's/},{/},\n  {/g; s/^{/  {/'
  printf '\n]\n'
} > "$MATCHES_JSON"

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
{
  printf 'WordPress core version audit\n'
  printf '============================\n'
  printf 'Run:            %s\n' "$STAMP"
  printf 'Auth:           %s\n' "$WHO"
  printf 'Affected ranges: %s\n' "${RANGE_LABEL[*]}"
  printf 'Environment:    %s\n' "$ENVIRONMENT"
  printf 'Scope:          %s\n\n' "$SCOPE_LABEL"
  printf 'Sites returned:      %s\n' "$TOTAL"
  printf 'Non-WordPress:       %s (skipped)\n' "$SKIPPED_NONWP"
  printf 'Frozen skipped:      %s\n' "$SKIPPED_FROZEN"
  printf 'Scanned:             %s\n' "$SCANNED"
  printf 'Errors/no version:   %s\n' "$ERRORS"
  printf 'AFFECTED sites:      %s\n' "$MATCHED"
} | tee "$SUMMARY" >&2

# ----------------------------------------------------------------------------
# End-of-run alert
# ----------------------------------------------------------------------------
if [ -t 2 ]; then RED=$'\033[1;31m'; GRN=$'\033[1;32m'; RST=$'\033[0m'; else RED=""; GRN=""; RST=""; fi

info ""
if [ "$MATCHED" -gt 0 ]; then
  info "${RED}================================================================${RST}"
  info "${RED} ⚠  ALERT: ${MATCHED} site(s) are running an AFFECTED WordPress core"
  info "${RED}    version (ranges: ${RANGE_LABEL[*]}).${RST}"
  info "${RED}================================================================${RST}"
  # Echo the affected sites inline for immediate visibility.
  tail -n +2 "$MATCHES_CSV" | while IFS=, read -r s e v r; do
    info "${RED}    • ${s} (${e}) — ${v}  [${r}]${RST}"
  done
  info ""
  info "Details: ${MATCHES_CSV}"
else
  info "${GRN}✓ No sites found in the affected version ranges.${RST}"
fi

info ""
info "Report written to: ${OUTDIR}"
info "  matches.csv   — affected sites"
info "  matches.json  — same, machine-readable"
info "  scan-full.csv — every site scanned, with status"
info "  summary.txt   — this summary"

[ "$MATCHED" -gt 0 ] && exit 2 || exit 0
