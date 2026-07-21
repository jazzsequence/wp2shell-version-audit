# WordPress Core Version Audit + Upstream Remediation (Pantheon / Terminus)

[![Unofficial Support](https://img.shields.io/badge/Pantheon-Unofficial_Support-yellow?logo=pantheon&color=FFDC28)](https://docs.pantheon.io/oss-support-levels#unofficial-support)

Two self-contained Bash scripts for auditing WordPress core versions across your
Pantheon sites and remediating them via upstream updates:

1. **`audit-wp-core-versions.sh`** — scans your sites and reports the ones whose
   WordPress core version falls within one or more **affected version ranges**.
2. **`apply-upstream-updates.sh`** — takes the audit results and applies upstream
   updates, but only to sites whose upstream can actually receive them; it
   reports the rest (custom / external-VCS upstreams) for manual updating.

Nothing personal is hardcoded. Site discovery uses Terminus scope filters, so
anyone with an authenticated Terminus session can run these against their own
sites, unchanged. Share freely.

## Requirements

- [Terminus](https://docs.pantheon.io/terminus) (3.x or 4.x) on your `PATH`
- An authenticated session: `terminus auth:login --machine-token=<token>`
- `bash` (3.2+) and standard coreutils — macOS and Linux both work

---

## 1. Auditing — `audit-wp-core-versions.sh`

Default affected ranges: `6.9.0–6.9.4` and `7.0.0–7.0.1` (inclusive).

```bash
./audit-wp-core-versions.sh                        # default ranges, dev, sites you own
./audit-wp-core-versions.sh --org "My Org"         # scan an organization's sites
./audit-wp-core-versions.sh -s all -e live         # everything you can access, live env
./audit-wp-core-versions.sh -r 6.5.0-6.5.9         # custom ranges
```

### Options

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `-r, --ranges <spec>` | `AUDIT_RANGES` | `6.9.0-6.9.4,7.0.0-7.0.1` | Comma-separated **inclusive** ranges (`low-high`) |
| `-e, --env <env>` | `AUDIT_ENV` | `dev` | Environment to read the version from |
| `-s, --scope <scope>` | `AUDIT_SCOPE` | `me` | `me` \| `team` \| `org` \| `all` (see below) |
| `--org <id>` | `AUDIT_ORG` | `all` | Org name/label/UUID. **Implies `--scope org`** — no need to also pass `-s org` |
| `-d, --output <dir>` | `AUDIT_OUTPUT` | `./reports` | Parent directory for the run's report folder |
| `--include-frozen` | `AUDIT_INCLUDE_FROZEN` | off | Also scan frozen sites (skipped by default) |
| `-j, --jobs <n>` | `AUDIT_JOBS` | `5` | Max parallel version checks |
| `-h, --help` | — | — | Show usage |

Per-site version checks run in parallel (default 5 at a time); site discovery
(`site:list`) is a single call and is unaffected.

### Scope

`--scope` maps to a Terminus `site:list` filter:

| Scope | Terminus filter | Includes |
|---|---|---|
| `me` (default) | `--owner=me` | Only sites you personally own |
| `team` | `--team` | Sites you're a team member of |
| `org` | `--org=<id>` | Sites in your organization(s) — pass `--org "Name"` to target one (that alone selects org scope); `-s org` alone = all your orgs |
| `all` | *(none)* | Every site accessible to you |

> Note: `me` **excludes** sites owned by an organization or a teammate. If your
> sites live under a Pantheon org, use `--scope org` (or `all`).

### Output

`reports/wp-core-audit-<timestamp>/` containing:

- `matches.csv` — affected sites (`site,environment,wp_core_version,matched_range`)
- `matches.json` — the same, machine-readable
- `scan-full.csv` — every site considered, with a per-site `status`
- `summary.txt` — run parameters and totals

If any affected sites are found, a red **ALERT** banner is printed listing them.

### Version-comparison notes

- WordPress reports an `x.y.0` release as just `x.y` (e.g. `6.9`) — treated as
  equal to `6.9.0` and matched accordingly.
- Comparison is numeric and zero-padded, so `10.0` > `7.0.1` (not lexical).

---

## 2. Remediation — `apply-upstream-updates.sh`

Reads the audit's `matches.csv`, classifies each affected site by its Terminus
**upstream type**, and applies upstream updates only where they'll actually
work.

**Only `type == core` upstreams** (the Pantheon-maintained WordPress upstreams
that bundle and track WP core — "WordPress", "WordPress Composer Managed") are
auto-applied via `terminus upstream:updates:apply`. Everything else is
**excluded and reported**, because `upstream:updates:apply` can't move their core
version:

| Excluded type | Why | Where to update |
|---|---|---|
| `custom` | An org's custom upstream | Update the custom upstream's repo, then re-run |
| `icr` | Built with the GitHub/GitLab App — code on external VCS | Update WordPress in the site's own git repo |
| `product` | "Empty"/product upstream; WP is composer-managed | Update via the site's composer/repo |
| *other* | Anything else | Reported for manual review |

The updatable-type allowlist is configurable with `--updatable-types`.

### Safety

**Applies by default.** On an interactive terminal it prompts once for
confirmation before applying (skip with `-y`); with no terminal (cron/CI) it
proceeds without prompting. Use **`--dry-run` (`-n`)** to classify and report
with **no changes**.

```bash
./apply-upstream-updates.sh                        # apply, against newest audit report (prompts)
./apply-upstream-updates.sh --dry-run              # preview only, no changes
./apply-upstream-updates.sh -i reports/wp-core-audit-20260721-124620
./apply-upstream-updates.sh -y --updatedb --accept-upstream   # apply, no prompt
```

### Options

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `-i, --input <path>` | `APPLY_INPUT` | newest audit report | `matches.csv` or a report directory |
| `-d, --output <dir>` | `APPLY_OUTPUT` | `./reports` | Parent dir for this run's report |
| `--updatable-types <t>` | `APPLY_UPDATABLE_TYPES` | `core` | Upstream types to auto-apply |
| `-n, --dry-run` | `APPLY_DRY_RUN` | off (applies) | Classify + report only; make no changes |
| `--updatedb` | — | off | Pass `--updatedb` (Drupal only; harmless for WP) |
| `--accept-upstream` | — | off | Auto-resolve conflicts in favor of upstream |
| `--no-verify` | — | verify on | Skip the post-apply WP-version re-check |
| `-y, --yes` | `APPLY_YES` | off | Skip the confirmation prompt |
| `-j, --jobs <n>` | `APPLY_JOBS` | `5` | Max parallel operations (classification + apply) |
| `-h, --help` | — | — | Show usage |

Both the classification pass and the apply pass run in parallel (default 5 at a
time).

### Output

`reports/upstream-apply-<timestamp>/` containing:

- `classification.csv` — every affected site, its upstream, site org, and the decision (`apply`/`exclude`)
- `excluded-upstreams.csv` — upstreams needing manual update, grouped, with repo URL and the affected sites (each with version + org)
- `applied.csv` — per-site apply results (execute mode): `old → new` version, status, notes
- `summary.txt` — counts + the list of upstreams needing attention

In execute mode with verification on, an applied `core` site whose version
**didn't change** is flagged `no-change` — a signal the upstream itself may be
behind or not tracking core.

### Exit codes (both scripts)

| Code | Meaning |
|---|---|
| `0` | Clean — nothing flagged |
| `1` | Usage / precondition error |
| `2` | Findings: audit → affected sites found; apply → sites excluded or an apply failed |

Handy for CI/cron: a non-zero exit means "something needs attention."

---

## Typical workflow

```bash
# 1. Find affected sites (org scope, since sites live under an org)
./audit-wp-core-versions.sh --org "My Org"

# 2. Preview what would be auto-remediated vs. what needs manual work
./apply-upstream-updates.sh --dry-run

# 3. Apply to the core-upstream sites (prompts for confirmation)
./apply-upstream-updates.sh

# 4. Manually update the custom / external-VCS upstreams the report listed,
#    then re-audit to confirm.
./audit-wp-core-versions.sh --org "My Org"
```
