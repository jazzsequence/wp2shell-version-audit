#!/usr/bin/env bash
#
# apply-upstream-updates.sh
#
# Companion to audit-wp-core-versions.sh. Takes that audit's matches.csv and
# applies available Terminus upstream updates to each affected site, then checks
# whether the WordPress version actually moved out of the affected range.
#
# SCOPE: this PATCHES the WordPress version only. It does NOT detect or clean up
# a compromise -- if a site was already exploited, updating core leaves the
# database-level damage in place: rogue admin accounts, forged content/posts,
# and any data already exposed (e.g. leaked user hashes or secrets). (On
# Pantheon, immutable code + no PHP execution from uploads mean webshells are
# not an exposure vector.) For compromise detection (IOCs of the wp2shell
# chain), see Miriam Goldman's wp2shell-audit:
# https://github.com/miriamgoldman/wp2shell-audit
#
# Model: apply is ATTEMPTED on every affected site EXCEPT those whose upstream
# can't receive useful upstream updates:
#   - icr     : externally version-controlled (code lives outside Pantheon).
#   - product : empty/BYO upstream (nothing ships in it).
# For everyone else (core, custom, multisite, composer-managed, ...) we apply
# whatever upstream updates are available -- a custom upstream can still have
# updates; they just might not include a newer WordPress. After applying, the
# WP version is re-checked against the site's affected range:
#   - resolved       : WP moved out of the range.
#   - still-affected : updates applied (or none available) but WP is still in
#                      range -> the upstream doesn't carry the WP bump; reported
#                      with where WordPress actually comes from.
#
# SFTP: upstream:updates:apply requires Git mode. A site in SFTP mode is flipped
# to Git for the apply and restored to SFTP afterward -- UNLESS it has
# uncommitted SFTP changes, in which case it is skipped (never destroy unsaved
# work). Full per-site Terminus output goes to <report>/logs/.
#
# APPLIES BY DEFAULT. Use --dry-run (-n) to classify + report with NO changes.
# On a terminal it prompts once (skip with -y); with no terminal it proceeds.
#
# Requirements: bash (3.2+), terminus (>= 3.x), an authenticated session.
#
# Usage:
#   ./apply-upstream-updates.sh [options]
#
# Options:
#   -i, --input <path>      matches.csv, OR a report dir containing it.
#                           Default: newest ./reports/wp-core-audit-*/.
#   -d, --output <dir>      Parent dir for this run's report (default: ./reports).
#   -n, --dry-run           Classify + report only; make NO changes.
#       --updatedb          Pass --updatedb to upstream:updates:apply.
#       --accept-upstream   Pass --accept-upstream (auto-resolve conflicts in
#                           favor of upstream -- can overwrite local changes).
#       --no-verify         Skip the post-apply WP-version re-check.
#   -y, --yes               Don't prompt for confirmation before applying.
#   -j, --jobs <n>          Max parallel operations (default: 5).
#   -h, --help              Show this help and exit.
#
# Env var equivalents (flags win): APPLY_INPUT, APPLY_OUTPUT, APPLY_DRY_RUN,
# APPLY_YES, APPLY_JOBS.
#
# Exit codes:
#   0  clean: every affected site resolved (or nothing to do)
#   1  usage / precondition error
#   2  completed, but some sites still need attention (still-affected, skipped,
#      or failed) -- see the report

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
INPUT="${APPLY_INPUT:-}"
OUTPUT_PARENT="${APPLY_OUTPUT:-./reports}"
if [ "${APPLY_DRY_RUN:-0}" = "1" ]; then EXECUTE=0; else EXECUTE=1; fi
ASSUME_YES="${APPLY_YES:-0}"
DO_UPDATEDB=0
DO_ACCEPT=0
DO_VERIFY=1
JOBS="${APPLY_JOBS:-5}"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
err()  { printf 'ERROR: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
usage() { awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

# Bounded parallel pool: block until fewer than $JOBS bg jobs are running.
throttle() { while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.15; done; }

# Split a tab line from FILE ($1) into F1..F9, preserving empty fields.
parse_tsv9() {
  local line
  IFS= read -r line < "$1" 2>/dev/null || line=""
  F1="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F2="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F3="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F4="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F5="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F6="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F7="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F8="${line%%$'\t'*}"; line="${line#*$'\t'}"
  F9="$line"
}

# Version comparison (numeric, zero-padded so "6.9" == "6.9.0").
sanitize_version() { printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//; s/\.$//'; }
version_cmp() {
  local IFS=. i x y; local -a A B
  read -ra A <<<"$1"; read -ra B <<<"$2"
  for i in 0 1 2 3; do
    x=$(( 10#${A[i]:-0} )); y=$(( 10#${B[i]:-0} ))
    (( x < y )) && { printf -- '-1'; return; }
    (( x > y )) && { printf -- '1';  return; }
  done
  printf -- '0'
}
in_range() { [ "$(version_cmp "$2" "$1")" -le 0 ] && [ "$(version_cmp "$1" "$3")" -le 0 ]; }
# True if $1 is still inside the inclusive range spec "$2" ("low-high").
still_in_range() {
  local lo hi; lo="${2%%-*}"; hi="${2##*-}"
  [ -n "$lo" ] && [ -n "$hi" ] || return 1
  in_range "$(sanitize_version "$1")" "$lo" "$hi"
}

is_pantheon_repo() {
  case "$1" in
    *github.com/pantheon-systems/*|*github.com/pantheon-upstreams/*) return 0 ;;
    *) return 1 ;;
  esac
}

# apply is attempted for everything except icr/product upstreams.
is_skip_type() { case "$1" in icr|product) return 0 ;; *) return 1 ;; esac; }

# Human guidance for a site that needs manual attention, by upstream type/repo.
guidance() {  # $1=type $2=repo
  case "$1" in
    icr)     printf 'externally version-controlled — update WordPress in the external repository' ;;
    product) printf 'empty/BYO upstream — update WordPress in the site codebase' ;;
    core)    printf 'already on the latest Pantheon upstream — no newer WordPress published there yet' ;;
    custom)
      if is_pantheon_repo "$2"; then
        printf 'Pantheon-maintained upstream is behind — no newer WordPress available there yet'
      else
        printf 'custom upstream — update the custom upstream repo itself, then re-run'
      fi ;;
    *) printf 'review manually' ;;
  esac
}

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)         INPUT="${2:?--input needs a value}"; shift 2 ;;
    -d|--output)        OUTPUT_PARENT="${2:?--output needs a value}"; shift 2 ;;
    -n|--dry-run)       EXECUTE=0; shift ;;
    --updatedb)         DO_UPDATEDB=1; shift ;;
    --accept-upstream)  DO_ACCEPT=1; shift ;;
    --no-verify)        DO_VERIFY=0; shift ;;
    -y|--yes)           ASSUME_YES=1; shift ;;
    -j|--jobs)          JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -h|--help)          usage 0 ;;
    *) err "Unknown option: $1"; usage 1 ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*) err "--jobs must be a positive integer"; exit 1 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
command -v terminus >/dev/null 2>&1 || { err "terminus not on PATH."; exit 1; }
terminus auth:whoami >/dev/null 2>&1 || { err "No Terminus session. Run: terminus auth:login --machine-token=<token>"; exit 1; }

# ----------------------------------------------------------------------------
# Resolve input matches.csv and read affected sites
# ----------------------------------------------------------------------------
if [ -z "$INPUT" ]; then
  INPUT="$(ls -dt "${OUTPUT_PARENT%/}"/wp-core-audit-*/ 2>/dev/null | head -n1 || true)"
  [ -n "$INPUT" ] || { err "No audit report under ${OUTPUT_PARENT}. Run the audit first, or pass --input."; exit 1; }
fi
[ -d "$INPUT" ] && INPUT="${INPUT%/}/matches.csv"
[ -f "$INPUT" ] || { err "matches.csv not found at: $INPUT"; exit 1; }

AFF_SITE=(); AFF_ENV=(); AFF_VER=(); AFF_RANGE=()
while IFS=, read -r c_site c_env c_ver c_range; do
  [ -z "$c_site" ] && continue
  AFF_SITE+=("$c_site"); AFF_ENV+=("$c_env"); AFF_VER+=("$c_ver"); AFF_RANGE+=("$c_range")
done < <(tail -n +2 "$INPUT")
N=${#AFF_SITE[@]}
[ "$N" -gt 0 ] || { err "No affected sites in $INPUT -- nothing to do."; exit 0; }

# ----------------------------------------------------------------------------
# Output directory
# ----------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTPUT_PARENT%/}/upstream-apply-${STAMP}"
LOGDIR="${OUTDIR}/logs"
mkdir -p "$LOGDIR"
CLASS_CSV="${OUTDIR}/classification.csv"
APPLIED_CSV="${OUTDIR}/applied.csv"
MANUAL_CSV="${OUTDIR}/needs-manual.csv"
MANUAL_TSV="${OUTDIR}/.manual.tsv"     # working; site \t version \t label \t type \t org \t reason
SUMMARY="${OUTDIR}/summary.txt"
: > "$MANUAL_TSV"
printf 'site,environment,wp_core_version,matched_range,upstream_type,upstream_label,site_org,decision\n' > "$CLASS_CSV"
printf 'site,environment,upstream_label,old_version,new_version,status,reason\n' > "$APPLIED_CSV"

MODE="DRY-RUN (no changes)"; [ "$EXECUTE" = "1" ] && MODE="APPLY"
info "Input:            $INPUT"
info "Affected sites:   $N"
info "Mode:             $MODE"
info "Output directory: $OUTDIR"
info ""

# ----------------------------------------------------------------------------
# Org UUID -> label map (site:info returns the org as a UUID)
# ----------------------------------------------------------------------------
ORG_MAP="${OUTDIR}/.org-map.tsv"
terminus org:list --fields=id,label --format=tsv 2>/dev/null | grep -v '^Deprecated' > "$ORG_MAP" || true
org_name() {
  [ -z "$1" ] && { printf 'unknown'; return; }
  local n; n="$(awk -F'\t' -v id="$1" '$1==id { print $2; exit }' "$ORG_MAP" 2>/dev/null || true)"
  printf '%s' "${n:-$1}"
}

# Stateless upstream lookup (safe for parallel workers). Echoes type<TAB>label<TAB>repo
lookup_upstream() {
  local uuid="$1" row t l r
  row="$(terminus upstream:info "$uuid" --fields=type,label,repository_url --format=tsv 2>/dev/null | grep -v '^Deprecated' | tail -n1 || true)"
  IFS=$'\t' read -r t l r <<<"$row" || true
  printf '%s\t%s\t%s' "${t:-unknown}" "${l:-?}" "${r:-}"
}

# ----------------------------------------------------------------------------
# Phase 1: classify (parallel, no mutation). Gather each site's upstream + org
# and decide apply vs skip (icr/product). Result columns:
#   site,env,ver,range,type,label,repo,site_org,decision
# ----------------------------------------------------------------------------
CL_WORK="$(mktemp -d)"
trap 'rm -rf "$CL_WORK"' EXIT

classify_worker() {
  local idx="$1" site="$2" env="$3" ver="$4" range="$5"
  local srow uf org_uuid uuid site_org u_type u_label u_repo decision
  srow="$(terminus site:info "$site" --fields=upstream,organization --format=tsv 2>/dev/null | grep -v '^Deprecated' | tail -n1 || true)"
  uf="${srow%%$'\t'*}"
  org_uuid="${srow#*$'\t'}"; [ "$org_uuid" = "$srow" ] && org_uuid=""
  uuid="${uf%%:*}"; uuid="$(printf '%s' "$uuid" | tr -d '[:space:]')"
  site_org="$(org_name "$org_uuid")"
  if [ -z "$uuid" ]; then
    u_type="unknown"; u_label="(unknown)"; u_repo=""
  else
    IFS=$'\t' read -r u_type u_label u_repo <<<"$(lookup_upstream "$uuid")" || true
  fi
  if is_skip_type "$u_type"; then decision="skip"; else decision="apply"; fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$site" "$env" "$ver" "$range" "$u_type" "$u_label" "$u_repo" "$site_org" "$decision" > "${CL_WORK}/${idx}"
  printf '  [%-5s] %-30s %s [%s]\n' "$decision" "$site" "$u_label" "$u_type" >&2
}

info "Classifying ${N} site(s), up to ${JOBS} in parallel ..."
i=0
while [ "$i" -lt "$N" ]; do
  throttle
  classify_worker "$i" "${AFF_SITE[$i]}" "${AFF_ENV[$i]}" "${AFF_VER[$i]}" "${AFF_RANGE[$i]}" &
  i=$((i + 1))
done
wait

# Aggregate: build the apply list; skipped (icr/product) go straight to manual.
APPLY_SITE=(); APPLY_ENV=(); APPLY_OLD=(); APPLY_RANGE=(); APPLY_TYPE=(); APPLY_LABEL=(); APPLY_REPO=(); APPLY_ORG=()
SKIP_COUNT=0
i=0
while [ "$i" -lt "$N" ]; do
  parse_tsv9 "${CL_WORK}/${i}"; idx=$i; i=$((i + 1))
  [ -z "$F1" ] && { F1="${AFF_SITE[$idx]}"; F2="${AFF_ENV[$idx]}"; F3="${AFF_VER[$idx]}"; F4="${AFF_RANGE[$idx]}"; F5="unknown"; F6="(worker-error)"; F7=""; F8="unknown"; F9="skip"; }
  # site,env,ver,range,type,label,repo,site_org,decision
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$F1" "$F2" "$F3" "$F4" "$F5" "$F6" "$F8" "$F9" >> "$CLASS_CSV"
  if [ "$F9" = "apply" ]; then
    APPLY_SITE+=("$F1"); APPLY_ENV+=("$F2"); APPLY_OLD+=("$F3"); APPLY_RANGE+=("$F4")
    APPLY_TYPE+=("$F5"); APPLY_LABEL+=("$F6"); APPLY_REPO+=("$F7"); APPLY_ORG+=("$F8")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$F1" "$F3" "$F6" "$F5" "$F8" "$(guidance "$F5" "$F7")" >> "$MANUAL_TSV"
    SKIP_COUNT=$((SKIP_COUNT + 1))
  fi
done
rm -rf "$CL_WORK"; trap - EXIT
APPLY_N=${#APPLY_SITE[@]}

# ----------------------------------------------------------------------------
# Phase 2: apply (execute only, parallel).
# ----------------------------------------------------------------------------
RESOLVED=0; STILL=0; FAILED=0; SKIPPED_UNCOMMITTED=0
if [ "$EXECUTE" = "1" ] && [ "$APPLY_N" -gt 0 ]; then
  if [ "$ASSUME_YES" != "1" ]; then
    if [ -t 0 ]; then
      printf 'Apply available upstream updates to %d site(s)? [y/N] ' "$APPLY_N" >&2
      read -r ans
      case "$ans" in y|Y|yes|YES) : ;; *) info "Aborted. (Use --dry-run to preview.)"; exit 1 ;; esac
    else
      info "Non-interactive: applying to ${APPLY_N} site(s). (Pass --dry-run to preview.)"
    fi
  fi

  AP_WORK="$(mktemp -d)"
  trap 'rm -rf "$AP_WORK"' EXIT

  has_uncommitted() { terminus env:diffstat "$1" --format=csv </dev/null 2>/dev/null | grep -v '^Deprecated' | tail -n +2 | grep -q .; }
  extract_reason() {
    local r
    r="$(printf '%s' "$1" | tr -d '\r' | grep -iE '\[(error|warning)\]' | sed -E 's/.*\[(error|warning)\][[:space:]]*//' | tail -n1)"
    [ -z "$r" ] && r="$(printf '%s' "$1" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n1)"
    printf '%s' "$r" | tr '\n\r\t,' '    ' | sed 's/  */ /g'
  }

  # Emits: site,env,label,old,new,status,type,org,reason  (status: resolved|still-affected|failed|skipped-uncommitted)
  apply_worker() {
    set +e
    local idx="$1" site="$2" env="$3" old="$4" range="$5" type="$6" label="$7" repo="$8" org="$9"
    local logf mode restore_sftp=0 out rc new status reason
    logf="${LOGDIR}/${site}.${env}.log"

    mode="$(terminus env:info "${site}.${env}" --field=connection_mode </dev/null 2>/dev/null | tr -d '[:space:]')"
    if [ "$mode" = "sftp" ]; then
      if has_uncommitted "${site}.${env}"; then
        reason="uncommitted SFTP changes; commit (terminus env:commit ${site}.${env}) or discard then re-run"
        reason="$(printf '%s' "$reason" | tr '\n\r\t,' '    ' | sed 's/  */ /g')"
        printf '  [SKIP]     %s.%s: uncommitted changes — left untouched\n' "$site" "$env" >&2
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$env" "$label" "$old" "$old" "skipped-uncommitted" "$type" "$org" "$reason" > "${AP_WORK}/${idx}"
        return
      fi
      printf '[connection] %s.%s sftp -> git\n' "$site" "$env" >> "$logf"
      terminus connection:set "${site}.${env}" git -y </dev/null >>"$logf" 2>&1 && restore_sftp=1
    fi

    out="$(terminus upstream:updates:apply "${site}.${env}" \
      $( [ "$DO_UPDATEDB" = 1 ] && printf -- '--updatedb' ) \
      $( [ "$DO_ACCEPT" = 1 ] && printf -- '--accept-upstream' ) \
      -y </dev/null 2>&1)"
    rc=$?
    printf '%s\n' "$out" >> "$logf"

    new="$old"
    if [ "$rc" -ne 0 ]; then
      status="failed"; reason="apply failed: $(extract_reason "$out")"
      printf '  [FAIL]     %s.%s: %s\n' "$site" "$env" "$reason" >&2
    else
      [ "$DO_VERIFY" = "1" ] && { new="$(terminus remote:wp "${site}.${env}" -- core version </dev/null 2>/dev/null | tr -d '\r' | tail -n1)"; new="${new:-$old}"; }
      if [ "$DO_VERIFY" = "1" ] && still_in_range "$new" "$range"; then
        status="still-affected"; reason="applied, but WP still ${new} — $(guidance "$type" "$repo")"
        printf '  [STILL]    %s.%s: still %s — %s\n' "$site" "$env" "$new" "$(guidance "$type" "$repo")" >&2
      else
        status="resolved"; reason="updated ${old} -> ${new}"
        printf '  [ok]       %s.%s (%s -> %s)\n' "$site" "$env" "$old" "$new" >&2
      fi
    fi

    if [ "$restore_sftp" = "1" ]; then
      printf '[connection] %s.%s git -> sftp (restore)\n' "$site" "$env" >> "$logf"
      terminus connection:set "${site}.${env}" sftp -y </dev/null >>"$logf" 2>&1
    fi
    reason="$(printf '%s' "$reason" | tr '\n\r\t,' '    ' | sed 's/  */ /g')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$env" "$label" "$old" "$new" "$status" "$type" "$org" "$reason" > "${AP_WORK}/${idx}"
  }

  info ""
  info "Applying to ${APPLY_N} site(s), up to ${JOBS} in parallel (logs: ${LOGDIR}/) ..."
  j=0
  while [ "$j" -lt "$APPLY_N" ]; do
    throttle
    apply_worker "$j" "${APPLY_SITE[$j]}" "${APPLY_ENV[$j]}" "${APPLY_OLD[$j]}" "${APPLY_RANGE[$j]}" \
      "${APPLY_TYPE[$j]}" "${APPLY_LABEL[$j]}" "${APPLY_REPO[$j]}" "${APPLY_ORG[$j]}" &
    j=$((j + 1))
  done
  wait

  # Aggregate apply results.
  j=0
  while [ "$j" -lt "$APPLY_N" ]; do
    parse_tsv9 "${AP_WORK}/${j}"; j=$((j + 1))
    # F1 site F2 env F3 label F4 old F5 new F6 status F7 type F8 org F9 reason
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$F1" "$F2" "$F3" "$F4" "$F5" "$F6" "$F9" >> "$APPLIED_CSV"
    case "$F6" in
      resolved)            RESOLVED=$((RESOLVED + 1)) ;;
      still-affected)      STILL=$((STILL + 1)); printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$F1" "$F5" "$F3" "$F7" "$F8" "$F9" >> "$MANUAL_TSV" ;;
      skipped-uncommitted) SKIPPED_UNCOMMITTED=$((SKIPPED_UNCOMMITTED + 1)); printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$F1" "$F4" "$F3" "$F7" "$F8" "$F9" >> "$MANUAL_TSV" ;;
      *)                   FAILED=$((FAILED + 1)); printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$F1" "$F4" "$F3" "$F7" "$F8" "$F9" >> "$MANUAL_TSV" ;;
    esac
  done
  rm -rf "$AP_WORK"; trap - EXIT
fi

# ----------------------------------------------------------------------------
# needs-manual.csv (machine-readable) from MANUAL_TSV
# ----------------------------------------------------------------------------
printf 'site,wp_core_version,upstream_label,upstream_type,site_org,reason\n' > "$MANUAL_CSV"
if [ -s "$MANUAL_TSV" ]; then
  sort -t$'\t' -k4,4 -k1,1 "$MANUAL_TSV" | awk -F'\t' '{ printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", $1,$2,$3,$4,$5,$6 }' >> "$MANUAL_CSV"
fi
MANUAL_N=$(( $(wc -l < "$MANUAL_CSV") - 1 ))

# ----------------------------------------------------------------------------
# Human-readable report
# ----------------------------------------------------------------------------
rule() { printf '  %s\n' '------------------------------------------------------------------'; }
{
  printf '====================================================================\n'
  printf '  WordPress core patch via upstream updates  —  %s\n' "$MODE"
  printf '====================================================================\n'
  printf '  Run:            %s\n' "$STAMP"
  printf '  Source audit:   %s\n\n' "$INPUT"
  printf '  Affected sites ............ %s\n' "$N"
  if [ "$EXECUTE" = "1" ]; then
    printf '  Resolved (WP updated) ..... %s\n' "$RESOLVED"
    printf '  Need attention ............ %s  (still-affected %s, skipped %s, failed %s, not-applicable %s)\n' \
      "$MANUAL_N" "$STILL" "$SKIPPED_UNCOMMITTED" "$FAILED" "$SKIP_COUNT"
  else
    printf '  Would apply ............... %s\n' "$APPLY_N"
    printf '  Not applicable (icr/empty)  %s\n' "$SKIP_COUNT"
  fi

  printf '\n'; rule
  if [ "$EXECUTE" = "1" ]; then
    printf '  RESOLVED\n'; rule
    if [ "$RESOLVED" -gt 0 ]; then
      awk -F, 'NR>1 && $6=="resolved" { printf "    %-30s %s -> %s\n", $1, $4, $5 }' "$APPLIED_CSV"
    else
      printf '    (none)\n'
    fi
  else
    printf '  WOULD APPLY  (available upstream updates will be applied)\n'; rule
    if [ "$APPLY_N" -gt 0 ]; then
      k=0
      while [ "$k" -lt "$APPLY_N" ]; do
        printf '    %-30s %-9s %s\n' "${APPLY_SITE[$k]}" "${APPLY_OLD[$k]}" "${APPLY_LABEL[$k]}"
        k=$((k + 1))
      done
    else
      printf '    (none)\n'
    fi
  fi

  printf '\n'; rule
  printf '  NEEDS MANUAL ATTENTION  (%s)\n' "$MANUAL_N"; rule
  if [ "$MANUAL_N" -gt 0 ]; then
    sort -t$'\t' -k4,4 -k1,1 "$MANUAL_TSV" | awk -F'\t' '
      { printf "\n    - %s  (%s)\n", $1, $2
        printf "        upstream: %s [%s], org: %s\n", $3, $4, $5
        printf "        -> %s\n", $6 }'
  else
    printf '    (none — every affected site was resolved)\n'
  fi

  printf '\n'; rule
  printf '  Files: classification.csv  needs-manual.csv'
  [ "$EXECUTE" = "1" ] && printf '  applied.csv  logs/'
  printf '\n  Location: %s\n' "$OUTDIR"
} | tee "$SUMMARY" >&2

rm -f "$MANUAL_TSV" "$ORG_MAP"
[ "$MANUAL_N" -gt 0 ] && exit 2 || exit 0
