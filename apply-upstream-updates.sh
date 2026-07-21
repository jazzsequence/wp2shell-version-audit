#!/usr/bin/env bash
#
# apply-upstream-updates.sh
#
# Companion to audit-wp-core-versions.sh. Takes that audit's matches.csv,
# classifies each affected site by its Terminus upstream, and applies upstream
# updates ONLY to sites whose upstream can actually receive them.
#
# Only upstreams of type "core" (the Pantheon-maintained WordPress upstreams
# that bundle and track WP core -- e.g. "WordPress", "WordPress Composer
# Managed") are auto-updated via `terminus upstream:updates:apply`. Every other
# upstream is EXCLUDED and reported so you know where to update WordPress by
# hand:
#   - custom  : an org's custom upstream -- update the custom upstream's repo,
#               then re-run this script.
#   - icr     : sites built with the GitHub/GitLab App (external VCS) -- update
#               WordPress in the site's own git repository.
#   - product : "empty"/product upstreams where WP is composer-managed -- update
#               via the site's composer/repo.
#   - other   : anything else -- reported for manual review.
# The set of auto-updatable types is configurable (--updatable-types).
#
# APPLIES BY DEFAULT. Use --dry-run (-n) to classify + report with NO changes.
# Before applying, it prompts once for confirmation on an interactive terminal
# (skip with -y). With no terminal (cron/CI) it proceeds without prompting, so
# pass --dry-run in automation when you only want a report.
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
#       --updatable-types <t>   Comma/space list of upstream types to auto-apply
#                               (default: core).
#   -n, --dry-run               Classify + report only; make NO changes.
#       --updatedb              Pass --updatedb to upstream:updates:apply.
#       --accept-upstream       Pass --accept-upstream (auto-resolve conflicts).
#       --no-verify             Skip the post-apply WP-version re-check.
#   -y, --yes                   Don't prompt for confirmation before applying.
#   -h, --help                  Show this help and exit.
#
# Env var equivalents (flags win): APPLY_INPUT, APPLY_OUTPUT,
# APPLY_UPDATABLE_TYPES, APPLY_DRY_RUN, APPLY_YES.
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
UPDATABLE_TYPES="${APPLY_UPDATABLE_TYPES:-core}"
# Applies by default; dry-run is opt-in (flag or APPLY_DRY_RUN=1).
if [ "${APPLY_DRY_RUN:-0}" = "1" ]; then EXECUTE=0; else EXECUTE=1; fi
ASSUME_YES="${APPLY_YES:-0}"
DO_UPDATEDB=0
DO_ACCEPT=0
DO_VERIFY=1

err()  { printf 'ERROR: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }
usage() {
  awk 'NR>=2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
  exit "${1:-0}"
}

# ----------------------------------------------------------------------------
# Parse arguments
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)           INPUT="${2:?--input needs a value}"; shift 2 ;;
    -d|--output)          OUTPUT_PARENT="${2:?--output needs a value}"; shift 2 ;;
    --updatable-types)    UPDATABLE_TYPES="${2:?--updatable-types needs a value}"; shift 2 ;;
    -n|--dry-run)         EXECUTE=0; shift ;;
    --updatedb)           DO_UPDATEDB=1; shift ;;
    --accept-upstream)    DO_ACCEPT=1; shift ;;
    --no-verify)          DO_VERIFY=0; shift ;;
    -y|--yes)             ASSUME_YES=1; shift ;;
    -h|--help)            usage 0 ;;
    *) err "Unknown option: $1"; usage 1 ;;
  esac
done

# Normalise the updatable-types list to space-separated for matching.
UPDATABLE_TYPES="$(printf '%s' "$UPDATABLE_TYPES" | tr ',' ' ')"

is_updatable_type() {
  local t
  for t in $UPDATABLE_TYPES; do [ "$1" = "$t" ] && return 0; done
  return 1
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
CACHE="${OUTDIR}/.upstream-cache.tsv"
: > "$EXCLUDED_TSV"; : > "$CACHE"
printf 'site,environment,wp_core_version,upstream_type,upstream_label,upstream_id,site_org,decision\n' > "$CLASS_CSV"
printf 'site,environment,upstream_label,old_version,new_version,apply_status,note\n' > "$APPLIED_CSV"

MODE="DRY-RUN (no changes)"; [ "$EXECUTE" = "1" ] && MODE="EXECUTE"
info "Input:            $INPUT"
info "Affected sites:   $N"
info "Updatable types:  ${UPDATABLE_TYPES}"
info "Mode:             ${MODE}"
info "Output directory: $OUTDIR"
info ""

# ----------------------------------------------------------------------------
# Look up an upstream's details by UUID, cached. Echoes: type<TAB>label<TAB>repo<TAB>org
# ----------------------------------------------------------------------------
lookup_upstream() {
  local uuid="$1" line row t l r o
  line="$(grep -m1 "^${uuid}"$'\t' "$CACHE" 2>/dev/null || true)"
  if [ -z "$line" ]; then
    row="$(terminus upstream:info "$uuid" \
      --fields=type,label,repository_url,organization --format=tsv 2>/dev/null \
      | grep -v '^Deprecated' | tail -n1 || true)"
    IFS=$'\t' read -r t l r o <<<"$row"
    line="${uuid}"$'\t'"${t:-unknown}"$'\t'"${l:-?}"$'\t'"${r:-}"$'\t'"${o:-}"
    printf '%s\n' "$line" >> "$CACHE"
  fi
  # strip leading uuid + tab, return the rest
  printf '%s' "${line#*$'\t'}"
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
# Phase 1: classify every affected site by upstream (no mutation).
# ----------------------------------------------------------------------------
APPLY_SITE=(); APPLY_ENV=(); APPLY_VER=(); APPLY_LABEL=()
EXCLUDED_COUNT=0
i=0
while [ "$i" -lt "$N" ]; do
  site="${AFF_SITE[$i]}"; env="${AFF_ENV[$i]}"; ver="${AFF_VER[$i]}"
  i=$((i + 1))
  printf '[%d/%d] %s ... ' "$i" "$N" "$site" >&2

  # One call gets both the upstream (uuid: url) and the site's org UUID.
  srow="$(terminus site:info "$site" --fields=upstream,organization --format=tsv 2>/dev/null | grep -v '^Deprecated' | tail -n1 || true)"
  uf="${srow%%$'\t'*}"
  org_uuid="${srow#*$'\t'}"; [ "$org_uuid" = "$srow" ] && org_uuid=""
  uuid="${uf%%:*}"; uuid="$(printf '%s' "$uuid" | tr -d '[:space:]')"
  site_org="$(org_name "$org_uuid")"

  if [ -z "$uuid" ]; then
    printf 'could not resolve upstream\n' >&2
    printf '%s,%s,%s,unknown,?,,%s,exclude\n' "$site" "$env" "$ver" "$site_org" >> "$CLASS_CSV"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "" "unknown" "(unknown)" "" "$site" "$ver" "$site_org" >> "$EXCLUDED_TSV"
    EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
    continue
  fi

  IFS=$'\t' read -r u_type u_label u_repo u_org <<<"$(lookup_upstream "$uuid")"

  if is_updatable_type "$u_type"; then
    printf '%s [%s] -> will apply\n' "$u_label" "$u_type" >&2
    printf '%s,%s,%s,%s,%s,%s,%s,apply\n' "$site" "$env" "$ver" "$u_type" "$u_label" "$uuid" "$site_org" >> "$CLASS_CSV"
    APPLY_SITE+=("$site"); APPLY_ENV+=("$env"); APPLY_VER+=("$ver"); APPLY_LABEL+=("$u_label")
  else
    printf '%s [%s] -> EXCLUDED\n' "$u_label" "$u_type" >&2
    printf '%s,%s,%s,%s,%s,%s,%s,exclude\n' "$site" "$env" "$ver" "$u_type" "$u_label" "$uuid" "$site_org" >> "$CLASS_CSV"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$uuid" "$u_type" "$u_label" "$u_repo" "$site" "$ver" "$site_org" >> "$EXCLUDED_TSV"
    EXCLUDED_COUNT=$((EXCLUDED_COUNT + 1))
  fi
done

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
  info "Applying upstream updates ..."
  j=0
  while [ "$j" -lt "$APPLY_N" ]; do
    site="${APPLY_SITE[$j]}"; env="${APPLY_ENV[$j]}"; old="${APPLY_VER[$j]}"; label="${APPLY_LABEL[$j]}"
    j=$((j + 1))
    printf '[%d/%d] apply %s.%s ... ' "$j" "$APPLY_N" "$site" "$env" >&2

    set +e
    terminus upstream:updates:apply "${site}.${env}" \
      $( [ "$DO_UPDATEDB" = 1 ] && printf -- '--updatedb' ) \
      $( [ "$DO_ACCEPT" = 1 ] && printf -- '--accept-upstream' ) \
      -y </dev/null >/dev/null 2>&1
    rc=$?
    set -e

    new="$old"; status="applied"; note=""
    if [ "$rc" -ne 0 ]; then
      status="apply-failed"; note="terminus exit $rc"
      APPLIED_FAILED=$((APPLIED_FAILED + 1))
      printf 'FAILED (exit %s)\n' "$rc" >&2
    else
      if [ "$DO_VERIFY" = "1" ]; then
        new="$(terminus remote:wp "${site}.${env}" -- core version </dev/null 2>/dev/null | tr -d '\r' | tail -n1 || true)"
        new="${new:-$old}"
      fi
      if [ "$DO_VERIFY" = "1" ] && [ "$new" = "$old" ]; then
        status="no-change"; note="version still ${new}; upstream may not track core"
        APPLIED_NOCHANGE=$((APPLIED_NOCHANGE + 1))
        printf 'applied but version unchanged (%s)\n' "$new" >&2
      else
        APPLIED_OK=$((APPLIED_OK + 1))
        printf 'ok (%s -> %s)\n' "$old" "$new" >&2
      fi
    fi
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$site" "$env" "$label" "$old" "$new" "$status" "$note" >> "$APPLIED_CSV"
  done
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
  printf '  Source audit:    %s\n' "$INPUT"
  printf '  Updatable types: %s\n\n' "$UPDATABLE_TYPES"
  printf '  Affected sites ............... %s\n' "$N"
  printf '  Auto-updatable (core) ........ %s\n' "$APPLY_N"
  printf '  Excluded (need attention) .... %s\n' "$EXCLUDED_COUNT"

  printf '\n'; rule
  if [ "$EXECUTE" = "1" ]; then
    printf '  APPLIED  (core upstreams)\n'; rule
    if [ "$APPLY_N" -gt 0 ]; then
      printf '    %-30s %-18s %s\n' "SITE" "VERSION" "RESULT"
      tail -n +2 "$APPLIED_CSV" | while IFS=, read -r s e lbl old new st note; do
        printf '    %-30s %-18s %s%s\n' "$s" "${old} -> ${new}" "$st" "$( [ -n "$note" ] && printf '  (%s)' "$note" )"
      done
    else
      printf '    (none)\n'
    fi
  else
    printf '  AUTO-UPDATABLE  (core upstreams — run with --execute to apply)\n'; rule
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
      function why(t){ if(t=="custom")  return "Custom upstream (organization-owned)."
                       if(t=="icr")     return "GitHub/GitLab App site — WordPress lives in external version control."
                       if(t=="product") return "Product/empty upstream — WordPress is composer-managed."
                       return "Upstream type is not auto-updatable via Terminus." }
      function fix(t){ if(t=="custom")  return "Update the custom upstream repo, then re-run this script."
                       if(t=="icr")     return "Update WordPress in the connected GitHub/GitLab repository."
                       if(t=="product") return "Update WordPress via composer.json in the site repository."
                       return "Review and update manually." }
      function flush(){
        printf "\n    * %s  [type: %s]\n", label, type
        printf "        why:   %s\n", why(type)
        printf "        fix:   %s\n", fix(type)
        if (repo!="") printf "        repo:  %s\n", repo
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

rm -f "$EXCLUDED_TSV" "$CACHE"

{ [ "$EXCLUDED_COUNT" -gt 0 ] || [ "$APPLIED_FAILED" -gt 0 ]; } && exit 2 || exit 0
