#!/usr/bin/env bash
#
# apply-upstream-updates.sh
#
# Companion to audit-wp-core-versions.sh. Takes that audit's matches.csv,
# classifies each affected site by its Terminus upstream, and applies upstream
# updates ONLY to sites whose upstream can actually receive them.
#
# A site is auto-updated via `terminus upstream:updates:apply` when its upstream
# is Pantheon-maintained:
#   - type=core                          -> apply
#   - type=custom AND Pantheon-owned repo -> apply (multisite/managed upstreams
#     are always type=custom but live under pantheon-systems/pantheon-upstreams)
# Everything else is EXCLUDED and reported with specific guidance:
#   - custom (org-owned repo) : update the custom upstream's own repo, re-run.
#   - icr                     : externally version-controlled -- update WordPress
#                               in the site's external VCS repository.
#   - product                 : empty/BYO upstream -- update WordPress in the
#                               site's own codebase.
#
# APPLIES BY DEFAULT. Use --dry-run (-n) to classify + report with NO changes.
# Before applying, it prompts once for confirmation on an interactive terminal
# (skip with -y). With no terminal (cron/CI) it proceeds without prompting, so
# pass --dry-run in automation when you only want a report.
#
# SFTP: upstream:updates:apply requires Git mode. If an environment is in SFTP
# mode, it is automatically flipped to Git for the apply and restored to SFTP
# afterward. Full per-site Terminus output is written to <report>/logs/.
#
# Requirements: bash (3.2+), terminus (>= 3.x), an authenticated session.
#
# Usage:
#   ./apply-upstream-updates.sh [options]
#
# Options:
#   -i, --input <path>          matches.csv, OR a report directory containing
#                               it. Default: newest ./reports/wp-core-audit-*/.
#   -d, --output <dir>          Parent dir for this run's report (default: ./reports).
#   -n, --dry-run               Classify + report only; make NO changes.
#       --updatedb              Pass --updatedb to upstream:updates:apply.
#       --accept-upstream       Pass --accept-upstream (auto-resolve conflicts).
#       --no-verify             Skip the post-apply WP-version re-check.
#   -y, --yes                   Don't prompt for confirmation before applying.
#   -j, --jobs <n>              Max parallel operations (default: 5).
#   -h, --help                  Show this help and exit.
#
# Env var equivalents (flags win): APPLY_INPUT, APPLY_OUTPUT, APPLY_DRY_RUN,
# APPLY_YES, APPLY_JOBS.
#
# Exit codes:
#   0  clean: nothing needs manual attention
#   1  usage / precondition error
#   2  completed, but sites were excluded (upstreams need manual update) and/or
#      an apply failed -- see the report

set -euo pipefail

# ----------------------------------------------------------------------------
# Defaults
# ----------------------------------------------------------------------------
INPUT="${APPLY_INPUT:-}"
OUTPUT_PARENT="${APPLY_OUTPUT:-./reports}"
# Applies by default; dry-run is opt-in (flag or APPLY_DRY_RUN=1).
if [ "${APPLY_DRY_RUN:-0}" = "1" ]; then EXECUTE=0; else EXECUTE=1; fi
ASSUME_YES="${APPLY_YES:-0}"
DO_UPDATEDB=0
DO_ACCEPT=0
DO_VERIFY=1
JOBS="${APPLY_JOBS:-5}"

err()  { printf 'ERROR: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
usage() {
  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
  exit "${1:-0}"
}

# Block until fewer than $JOBS background jobs are running (bounded pool).
throttle() { while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$JOBS" ]; do sleep 0.15; done; }

# Split a tab-delimited line from FILE ($1) into globals F1..F9, preserving
# empty fields (a bash `read` with tab IFS would collapse them).
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

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)           INPUT="${2:?--input needs a value}"; shift 2 ;;
    -d|--output)          OUTPUT_PARENT="${2:?--output needs a value}"; shift 2 ;;
    -n|--dry-run)         EXECUTE=0; shift ;;
    --updatedb)           DO_UPDATEDB=1; shift ;;
    --accept-upstream)    DO_ACCEPT=1; shift ;;
    --no-verify)          DO_VERIFY=0; shift ;;
    -y|--yes)             ASSUME_YES=1; shift ;;
    -j|--jobs)            JOBS="${2:?--jobs needs a value}"; shift 2 ;;
    -h|--help)            usage 0 ;;
    *) err "Unknown option: $1"; usage 1 ;;
  esac
done

case "$JOBS" in ''|*[!0-9]*) err "--jobs must be a positive integer"; exit 1 ;; esac
[ "$JOBS" -lt 1 ] && JOBS=1

# True if a repo URL is a Pantheon-owned upstream repo.
is_pantheon_repo() {
  case "$1" in
    *github.com/pantheon-systems/*|*github.com/pantheon-upstreams/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Decide apply|exclude from upstream type + repo. Multisite upstreams are
# always type=custom but Pantheon-owned (per-site multisite upstreams), so a
# custom upstream whose repo is Pantheon-owned is still auto-updatable.
#   core                      -> apply
#   custom + Pantheon repo    -> apply (multisite / managed)
#   custom + non-Pantheon repo-> exclude (org's own custom upstream)
#   icr / product / other     -> exclude
decide_apply() {  # $1=type $2=repo ; echoes apply|exclude
  case "$1" in
    core)   printf 'apply' ;;
    custom) if is_pantheon_repo "$2"; then printf 'apply'; else printf 'exclude'; fi ;;
    *)      printf 'exclude' ;;
  esac
}

# ----------------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------------
command -v terminus >/dev/null 2>&1 || { err "terminus not on PATH."; exit 1; }
terminus auth:whoami >/dev/null 2>&1 || { err "No Terminus session. Run: terminus auth:login --machine-token=<token>"; exit 1; }

# ----------------------------------------------------------------------------
# Resolve the input matches.csv
# ----------------------------------------------------------------------------
if [ -z "$INPUT" ]; then
  INPUT="$(ls -dt "${OUTPUT_PARENT%/}"/wp-core-audit-*/ 2>/dev/null | head -n1 || true)"
  [ -n "$INPUT" ] || { err "No audit report found under ${OUTPUT_PARENT}. Run the audit first, or pass --input."; exit 1; }
fi
if [ -d "$INPUT" ]; then INPUT="${INPUT%/}/matches.csv"; fi
[ -f "$INPUT" ] || { err "matches.csv not found at: $INPUT"; exit 1; }

# Read affected sites (skip header). site,environment,wp_core_version,matched_range
AFF_SITE=(); AFF_ENV=(); AFF_VER=()
while IFS=, read -r c_site c_env c_ver c_rest; do
  [ -z "$c_site" ] && continue
  AFF_SITE+=("$c_site"); AFF_ENV+=("$c_env"); AFF_VER+=("$c_ver")
done < <(tail -n +2 "$INPUT")

N=${#AFF_SITE[@]}
[ "$N" -gt 0 ] || { err "No affected sites in $INPUT -- nothing to do."; exit 0; }

# ----------------------------------------------------------------------------
# Output directory
# ----------------------------------------------------------------------------
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTDIR="${OUTPUT_PARENT%/}/upstream-apply-${STAMP}"
mkdir -p "$OUTDIR"
CLASS_CSV="${OUTDIR}/classification.csv"
APPLIED_CSV="${OUTDIR}/applied.csv"
EXCLUDED_TSV="${OUTDIR}/.excluded.tsv"           # working file, grouped later
EXCLUDED_CSV="${OUTDIR}/excluded-upstreams.csv"
SUMMARY="${OUTDIR}/summary.txt"
LOGDIR="${OUTDIR}/logs"          # per-site raw Terminus output (apply phase)
mkdir -p "$LOGDIR"
: > "$EXCLUDED_TSV"
printf 'site,environment,wp_core_version,upstream_type,upstream_label,upstream_id,site_org,decision\n' > "$CLASS_CSV"
printf 'site,environment,upstream_label,old_version,new_version,apply_status,note\n' > "$APPLIED_CSV"

MODE="DRY-RUN (no changes)"; [ "$EXECUTE" = "1" ] && MODE="EXECUTE"
info "Input:            $INPUT"
info "Affected sites:   $N"
info "Mode:             ${MODE}"
info "Output directory: $OUTDIR"
info ""

# ----------------------------------------------------------------------------
# Look up an upstream's details by UUID. Stateless (no shared cache file) so it
# is safe to call from parallel workers. Echoes: type<TAB>label<TAB>repo
# ----------------------------------------------------------------------------
lookup_upstream() {
  local uuid="$1" row t l r
  row="$(terminus upstream:info "$uuid" --fields=type,label,repository_url --format=tsv 2>/dev/null | grep -v '^Deprecated' | tail -n1 || true)"
  IFS=$'\t' read -r t l r <<<"$row" || true
  printf '%s\t%s\t%s' "${t:-unknown}" "${l:-?}" "${r:-}"
}

# ----------------------------------------------------------------------------
# Organization UUID -> label map (site:info returns the org as a UUID). Built
# once from `org:list`; org_name() falls back to the UUID if not found.
# ----------------------------------------------------------------------------
ORG_MAP="${OUTDIR}/.org-map.tsv"
terminus org:list --fields=id,label --format=tsv 2>/dev/null | grep -v '^Deprecated' > "$ORG_MAP" || true
org_name() {
  [ -z "$1" ] && { printf 'unknown'; return; }
  local n
  n="$(awk -F'\t' -v id="$1" '$1==id { print $2; exit }' "$ORG_MAP" 2>/dev/null || true)"
  printf '%s' "${n:-$1}"
}

# ----------------------------------------------------------------------------
# Phase 1: classify every affected site by upstream — PARALLEL. Each worker
# resolves one site's upstream + org (no mutation) and writes a 9-field result
# line to its own file. Aggregation below is sequential/ordered (single writer).
#   result columns: site,env,ver,type,label,uuid,repo,site_org,decision
# ----------------------------------------------------------------------------
CL_WORK="$(mktemp -d)"
trap 'rm -rf "$CL_WORK"' EXIT

classify_worker() {
  local idx="$1" site="$2" env="$3" ver="$4"
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
  decision="$(decide_apply "$u_type" "$u_repo")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$site" "$env" "$ver" "$u_type" "$u_label" "$uuid" "$u_repo" "$site_org" "$decision" > "${CL_WORK}/${idx}"
  printf '  [%-7s] %-30s %s [%s]\n' "$decision" "$site" "$u_label" "$u_type" >&2
}

info "Classifying ${N} site(s), up to ${JOBS} in parallel ..."
i=0
while [ "$i" -lt "$N" ]; do
  throttle
  classify_worker "$i" "${AFF_SITE[$i]}" "${AFF_ENV[$i]}" "${AFF_VER[$i]}" &
  i=$((i + 1))
done
wait

# Aggregate classification (sequential, ordered, single writer).
APPLY_SITE=(); APPLY_ENV=(); APPLY_VER=(); APPLY_LABEL=()
EXCLUDED_COUNT=0
i=0
while [ "$i" -lt "$N" ]; do
  parse_tsv9 "${CL_WORK}/${i}"
  idx=$i; i=$((i + 1))
  if [ -z "$F1" ]; then   # worker produced no result
    F1="${AFF_SITE[$idx]}"; F2="${AFF_ENV[$idx]}"; F3="${AFF_VER[$idx]}"
    F4="unknown"; F5="(worker-error)"; F6=""; F7=""; F8="unknown"; F9="exclude"
  fi
  # F1 site F2 env F3 ver F4 type F5 label F6 uuid F7 repo F8 site_org F9 decision
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$F1" "$F2" "$F3" "$F4" "$F5" "$F6" "$F8" "$F9" >> "$CLASS_CSV"
  if [ "$F9" = "apply" ]; then
    APPLY_SITE+=("$F1"); APPLY_ENV+=("$F2"); APPLY_VER+=("$F3"); APPLY_LABEL+=("$F5")
  else
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$F6" "$F4" "$F5" "$F7" "$F1" "$F3" "$F8" >> "$EXCLUDED_TSV"
    EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
  fi
done
rm -rf "$CL_WORK"; trap - EXIT

APPLY_N=${#APPLY_SITE[@]}

# ----------------------------------------------------------------------------
# Build the grouped "excluded upstreams" report (group by uuid, join sites).
# ----------------------------------------------------------------------------
# EXCLUDED_TSV columns: uuid, up_type, up_label, up_repo, site, version, site_org
printf 'upstream_type,upstream_label,repository_url,affected_sites\n' > "$EXCLUDED_CSV"
if [ -s "$EXCLUDED_TSV" ]; then
  sort -t$'\t' -k1,1 "$EXCLUDED_TSV" | awk -F'\t' '
    function flush(){ if(started) print "\"" type "\",\"" label "\",\"" repo "\",\"" sites "\"" }
    { if(!started || $1!=key){ flush(); key=$1; type=$2; label=$3; repo=$4; sites=""; started=1 }
      one = $5 " (" $6 "; org: " $7 ")"
      sites = (sites=="" ? one : sites "; " one) }
    END { flush() }
  ' >> "$EXCLUDED_CSV"
fi

# ----------------------------------------------------------------------------
# Phase 2: apply (execute mode only).
# ----------------------------------------------------------------------------
APPLIED_OK=0; APPLIED_NOCHANGE=0; APPLIED_FAILED=0
if [ "$EXECUTE" = "1" ] && [ "$APPLY_N" -gt 0 ]; then
  if [ "$ASSUME_YES" != "1" ]; then
    if [ -t 0 ]; then
      printf 'About to apply upstream updates to %d site(s). Continue? [y/N] ' "$APPLY_N" >&2
      read -r ans
      case "$ans" in y|Y|yes|YES) : ;; *) info "Aborted. (Use --dry-run to preview without changes.)"; exit 1 ;; esac
    else
      info "Non-interactive: applying to ${APPLY_N} site(s). (Pass --dry-run to preview instead.)"
    fi
  fi

  info ""
  info "Applying to ${APPLY_N} site(s), up to ${JOBS} in parallel ..."
  info "Per-site Terminus output: ${LOGDIR}/"
  AP_WORK="$(mktemp -d)"
  trap 'rm -rf "$AP_WORK"' EXIT

  # Turn raw Terminus output into a one-line, comma/newline-free reason. Prefers
  # the [error]/[warning] message (stripped of timestamp+level).
  extract_reason() {
    local r
    r="$(printf '%s' "$1" | tr -d '\r' | grep -iE '\[(error|warning)\]' | sed -E 's/.*\[(error|warning)\][[:space:]]*//' | tail -n1)"
    [ -z "$r" ] && r="$(printf '%s' "$1" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n1)"
    printf '%s' "$r" | tr '\n\r\t,' '    ' | sed 's/  */ /g'
  }

  apply_worker() {
    set +e   # a failed apply is data, not a reason to abort the worker
    local idx="$1" site="$2" env="$3" old="$4" label="$5"
    local rc new status note out reason logf mode restore_sftp=0
    logf="${LOGDIR}/${site}.${env}.log"

    # upstream:updates:apply requires Git mode. If the env is in SFTP mode, flip
    # it to Git for the apply, then restore SFTP afterward so the site is left
    # exactly as we found it.
    mode="$(terminus env:info "${site}.${env}" --field=connection_mode </dev/null 2>/dev/null | tr -d '[:space:]')"
    if [ "$mode" = "sftp" ]; then
      printf '[connection] %s.%s sftp -> git\n' "$site" "$env" >> "$logf"
      if terminus connection:set "${site}.${env}" git -y </dev/null >>"$logf" 2>&1; then
        restore_sftp=1
      fi
    fi

    out="$(terminus upstream:updates:apply "${site}.${env}" \
      $( [ "$DO_UPDATEDB" = 1 ] && printf -- '--updatedb' ) \
      $( [ "$DO_ACCEPT" = 1 ] && printf -- '--accept-upstream' ) \
      -y </dev/null 2>&1)"
    rc=$?
    printf '%s\n' "$out" >> "$logf"

    new="$old"; status="applied"; note=""
    if [ "$rc" -ne 0 ]; then
      status="apply-failed"
      reason="$(extract_reason "$out")"
      note="exit ${rc}: ${reason}"
      printf '  [FAIL]     %s.%s: %s\n' "$site" "$env" "$reason" >&2
    else
      if [ "$DO_VERIFY" = "1" ]; then
        new="$(terminus remote:wp "${site}.${env}" -- core version </dev/null 2>/dev/null | tr -d '\r' | tail -n1)"
        new="${new:-$old}"
      fi
      if [ "$DO_VERIFY" = "1" ] && [ "$new" = "$old" ]; then
        status="no-change"
        reason="$(extract_reason "$out")"
        note="applied; version still ${new} (${reason:-see log})"
        printf '  [NOCHANGE] %s.%s still %s: %s\n' "$site" "$env" "$new" "${reason:-see log}" >&2
      else
        note="updated ${old} -> ${new}"
        printf '  [ok]       %s.%s (%s -> %s)\n' "$site" "$env" "$old" "$new" >&2
      fi
    fi

    # Restore SFTP mode if we flipped it.
    if [ "$restore_sftp" = "1" ]; then
      printf '[connection] %s.%s git -> sftp (restore)\n' "$site" "$env" >> "$logf"
      terminus connection:set "${site}.${env}" sftp -y </dev/null >>"$logf" 2>&1
    fi

    note="$(printf '%s' "$note" | tr '\n\r,' '   ' | sed 's/  */ /g')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$site" "$env" "$label" "$old" "$new" "$status" "$note" > "${AP_WORK}/${idx}"
  }

  j=0
  while [ "$j" -lt "$APPLY_N" ]; do
    throttle
    apply_worker "$j" "${APPLY_SITE[$j]}" "${APPLY_ENV[$j]}" "${APPLY_VER[$j]}" "${APPLY_LABEL[$j]}" &
    j=$((j + 1))
  done
  wait

  # Aggregate apply results (sequential, ordered, single writer).
  j=0
  while [ "$j" -lt "$APPLY_N" ]; do
    r_note=""
    IFS=$'\t' read -r r_site r_env r_label r_old r_new r_status r_note < "${AP_WORK}/${j}" || true
    j=$((j + 1))
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$r_site" "$r_env" "$r_label" "$r_old" "$r_new" "$r_status" "$r_note" >> "$APPLIED_CSV"
    case "$r_status" in
      applied)      APPLIED_OK=$((APPLIED_OK + 1)) ;;
      no-change)    APPLIED_NOCHANGE=$((APPLIED_NOCHANGE + 1)) ;;
      *)            APPLIED_FAILED=$((APPLIED_FAILED + 1)) ;;
    esac
  done
  rm -rf "$AP_WORK"; trap - EXIT
fi

# ----------------------------------------------------------------------------
# Human-readable report. The CSV/JSON files hold the machine-readable data;
# summary.txt (below) is written for humans and echoed to the terminal.
# ----------------------------------------------------------------------------
rule() { printf '  %s\n' '------------------------------------------------------------------'; }

{
  printf '====================================================================\n'
  printf '  WordPress upstream remediation  —  %s\n' "$MODE"
  printf '====================================================================\n'
  printf '  Run:             %s\n' "$STAMP"
  printf '  Source audit:    %s\n\n' "$INPUT"
  printf '  Affected sites ............... %s\n' "$N"
  printf '  Auto-updatable ............... %s\n' "$APPLY_N"
  printf '  Excluded (need attention) .... %s\n' "$EXCLUDED_COUNT"

  printf '\n'; rule
  if [ "$EXECUTE" = "1" ]; then
    printf '  APPLIED  (auto-updatable upstreams)\n'; rule
    if [ "$APPLY_N" -gt 0 ]; then
      printf '    %-30s %-18s %s\n' "SITE" "VERSION" "RESULT"
      tail -n +2 "$APPLIED_CSV" | while IFS=, read -r s e lbl old new st note; do
        printf '    %-30s %-18s %s%s\n' "$s" "${old} -> ${new}" "$st" "$( [ -n "$note" ] && printf '  (%s)' "$note" )"
      done
    else
      printf '    (none)\n'
    fi
  else
    printf '  AUTO-UPDATABLE  (Pantheon-maintained — run without --dry-run to apply)\n'; rule
    if [ "$APPLY_N" -gt 0 ]; then
      printf '    %-30s %-9s %s\n' "SITE" "VERSION" "UPSTREAM"
      k=0
      while [ "$k" -lt "$APPLY_N" ]; do
        printf '    %-30s %-9s %s\n' "${APPLY_SITE[$k]}" "${APPLY_VER[$k]}" "${APPLY_LABEL[$k]}"
        k=$((k + 1))
      done
    else
      printf '    (none)\n'
    fi
  fi

  printf '\n'; rule
  printf '  NEEDS MANUAL UPDATE  (%s site(s), grouped by upstream)\n' "$EXCLUDED_COUNT"; rule
  if [ "$EXCLUDED_COUNT" -gt 0 ]; then
    # Group by upstream and format entirely in awk. Fields (from EXCLUDED_TSV):
    #   $1 uuid  $2 type  $3 up_label  $4 up_repo  $5 site  $6 version  $7 site_org
    # -F'\t' preserves empty fields, which a bash `read` on tab data would
    # silently collapse. Each affected site is listed with its (never-empty) org.
    sort -t$'\t' -k1,1 "$EXCLUDED_TSV" | awk -F'\t' '
      function why(t){ if(t=="custom")  return "Custom upstream owned by your organization."
                       if(t=="icr")     return "Externally version-controlled site — WordPress lives in the connected external repository."
                       if(t=="product") return "Empty/BYO upstream — nothing ships in the upstream; WordPress lives in the site codebase."
                       return "Upstream is not auto-updatable via Terminus." }
      function fix(t){ if(t=="custom")  return "Update the custom upstream repo itself, then re-run this script."
                       if(t=="icr")     return "Update WordPress in the external version-control repository."
                       if(t=="product") return "Update WordPress in the site codebase directly."
                       return "Review and update manually." }
      function flush(){
        printf "\n    * %s  [type: %s]\n", label, type
        printf "        why:   %s\n", why(type)
        printf "        fix:   %s\n", fix(type)
        if (type=="custom" && repo!="") printf "        repo:  %s\n", repo
        printf "        sites:%s\n", sites
      }
      { if (!started || $1!=key) { if (started) flush(); key=$1; type=$2; label=$3; repo=$4; sites=""; started=1 }
        sites = sites sprintf("\n          - %-30s %-8s org: %s", $5, $6, $7) }
      END { if (started) flush() }
    '
  else
    printf '    (none — every affected site is on an auto-updatable upstream)\n'
  fi

  printf '\n'; rule
  printf '  Machine-readable: classification.csv, excluded-upstreams.csv'
  [ "$EXECUTE" = "1" ] && printf ', applied.csv'
  printf '\n  Location:         %s\n' "$OUTDIR"
} | tee "$SUMMARY" >&2

rm -f "$EXCLUDED_TSV" "$ORG_MAP"

{ [ "$EXCLUDED_COUNT" -gt 0 ] || [ "$APPLIED_FAILED" -gt 0 ]; } && exit 2 || exit 0
