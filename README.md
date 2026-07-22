# WordPress Core Version Audit + Patching (Pantheon / Terminus)

[![Unofficial Support](https://img.shields.io/badge/Pantheon-Unofficial_Support-yellow?logo=pantheon&color=FFDC28)](https://docs.pantheon.io/oss-support-levels#unofficial-support)

Two self-contained Bash scripts for auditing WordPress core versions across your
Pantheon sites and patching them (updating WordPress core) via upstream updates:

1. **`audit-wp-core-versions.sh`** — scans your sites and reports the ones whose
   WordPress core version falls within one or more **affected version ranges**.
2. **`apply-upstream-updates.sh`** — takes the audit results and applies available
   upstream updates to move WordPress core to the latest version, reporting any
   site the update didn't fix (custom / external-VCS / empty upstreams).

> ⚠️ **These tools patch the WordPress *version*. They do not remediate an
> attack.** If a site was already compromised, updating core does **not** remove
> the database-level damage — rogue admin accounts, forged content/posts, or any
> data already exposed (leaked user hashes, secrets) — that is separate incident
> response. (On Pantheon, immutable code and no PHP execution from `uploads/`
> mean webshells aren't an exposure vector, so the relevant damage is DB-level.)
> To *detect* whether a site shows signs of the wp2shell compromise chain
> (CVE-2026-60137 / CVE-2026-63030), use Miriam Goldman's read-only audit +
> Claude skill: **[wp2shell-audit](https://github.com/miriamgoldman/wp2shell-audit)**.
> Cleanup of a confirmed compromise is manual.

Nothing personal is hardcoded. Site discovery uses Terminus scope filters, so
anyone with an authenticated Terminus session can run these against their own
sites, unchanged. Share freely.

## Requirements

- [Terminus](https://docs.pantheon.io/terminus) (3.x or 4.x) on your `PATH`
- An authenticated session: `terminus auth:login --machine-token=<token>`
- `bash` (3.2+) and standard coreutils — macOS and Linux both work

---

## 1. Auditing — `audit-wp-core-versions.sh`

Default affected ranges: `6.8.0–6.8.5`, `6.9.0–6.9.4`, and `7.0.0–7.0.1`
(inclusive) — the versions affected by CVE-2026-60137 (WordPress 6.8 through
7.0.1; fixed per branch in 6.8.6 / 6.9.5 / 7.0.2).

```bash
./audit-wp-core-versions.sh                        # default ranges, dev, sites you own
./audit-wp-core-versions.sh --org "My Org"         # scan an organization's sites
./audit-wp-core-versions.sh -s all -e live         # everything you can access, live env
./audit-wp-core-versions.sh -r 6.5.0-6.5.9         # custom ranges
```

### Options

| Flag | Env var | Default | Meaning |
|---|---|---|---|
| `-r, --ranges <spec>` | `AUDIT_RANGES` | `6.8.0-6.8.5,6.9.0-6.9.4,7.0.0-7.0.1` | Comma-separated **inclusive** ranges (`low-high`) |
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

## 2. Patching — `apply-upstream-updates.sh`

Reads the audit's `matches.csv` and **applies whatever upstream updates are
available** to each affected site, then re-checks the WordPress version against
that site's affected range to see whether it actually helped.

**Apply is attempted on every affected site except** upstreams that can't receive
useful upstream updates:

| Skipped upstream | Why | Where WordPress comes from |
|---|---|---|
| `icr` | Externally version-controlled | The connected external repository |
| `product` | Empty/BYO upstream — nothing ships in it | The site's own codebase |

Every other upstream (`core`, `custom`, multisite, composer-managed, …) gets an
apply attempt — a custom upstream can still have upstream updates; they just may
not include a newer WordPress. After applying, each site is classified:

- **resolved** — WordPress moved out of the affected range ✅
- **still-affected** — updates applied (or none available) but WordPress is still
  in range → the upstream doesn't carry the WP bump; reported with the upstream's
  type/org and where to update WordPress (e.g. a `custom` org upstream → update
  that upstream's repo).

Everything needing manual attention — the skipped `icr`/`product` sites plus any
still-affected/failed/skipped-uncommitted — lands in one **NEEDS MANUAL
ATTENTION** list (and `needs-manual.csv`).

**SFTP handling & logs:** `upstream:updates:apply` requires Git connection mode.
If an environment is in SFTP mode, the script automatically flips it to Git for
the apply and restores SFTP afterward (leaving the site as it found it). A site
with **uncommitted SFTP changes is skipped** (never destroy unsaved work) and
reported. The full Terminus output for every site is captured to
`<report>/logs/<site>.<env>.log`, and any failure surfaces the real Terminus
error (e.g. merge conflicts, build failures) in the progress output,
`applied.csv`, and `summary.txt` — not a bare "exit 1".

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

- `classification.csv` — every affected site, its upstream, site org, and decision (`apply`/`skip`)
- `needs-manual.csv` — every site still needing attention (site, version, upstream, type, org, reason)
- `applied.csv` — per-site apply results (apply mode): `old → new` version, status, reason
- `logs/<site>.<env>.log` — full Terminus output per site (apply mode)
- `summary.txt` — the human-readable report (counts, resolved list, needs-manual list)

Each apply-mode site ends up as **resolved**, **still-affected**, **failed**, or
**skipped-uncommitted**; the last three (plus the skipped `icr`/`product` sites)
make up the NEEDS MANUAL ATTENTION list.

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

# 2. Preview what would be auto-patched vs. what needs manual work
./apply-upstream-updates.sh --dry-run

# 3. Apply available upstream updates (prompts for confirmation)
./apply-upstream-updates.sh

# 4. Manually update the sites the report flagged as still-affected
#    (icr/external-VCS, empty/BYO, and org-owned custom upstreams), then re-audit.
./audit-wp-core-versions.sh --org "My Org"
```

Patching only closes the *version* gap. For any site that was exposed before it
was patched, run a compromise check separately —
[wp2shell-audit](https://github.com/miriamgoldman/wp2shell-audit) (read-only IOC
audit + Claude skill) — and handle any confirmed compromise as incident response.
