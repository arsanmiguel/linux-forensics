# Security exceptions — linux-forensics

Intentional design choices for this **root-run diagnostic script**. Not a daemon or cloud deployment.

**Related:** [README.md](README.md)

---

## CSE / security scan handoff

**What this is:** Single Bash script (`invoke-linux-forensics.sh`) for read-mostly Linux/FreeBSD performance forensics, optional AWS Support case attachment.

**Run local automated scans (Docker / Colima):**

```bash
colima start   # if needed
./security-scan.sh
```

Reports default to `/tmp/linux-forensics-security-scan/` (Gitleaks, Trivy on script + README, optional shellcheck).

**Amazon Git Security Scanner (internal):** `.security-scan/config.yaml` from `cse init` — run your team’s snapshot scanner against this repo for full agent review. Prior snapshot (2026-06-30) flagged two issues **since fixed** in tree (see below).

**Scope:**

| Path | Role |
|------|------|
| `invoke-linux-forensics.sh` | Entire product |
| `README.md` | Operator docs (example IAM JSON is template only) |

**Before filing findings, read this doc.**

---

## Requires root (by design)

**Design:** Script must run as **root/sudo** to read `/proc`, performance counters, SMART, database diagnostics, and optional `dd` disk tests.

**Why:** Forensic/read-only system inspection on the host under investigation.

**Mitigation:** Run only on hosts you own; use `-m quick` or `-m standard` in production; reserve `-m deep` for maintenance windows.

---

## Optional package installation

**Design:** May invoke `apt`, `dnf`, `yum`, `zypper`, `pacman`, `apk`, or `pkg` to install missing **open-source** diagnostics (sysstat, smartmontools, etc.).

**Why:** Graceful degradation on minimal images; operator can pre-install packages to disable auto-install behavior indirectly (tools already present).

---

## AWS Support API (`-s` flag)

**Design:** When `-s` / `--support` is set and AWS CLI is configured, script calls `support:CreateCase` and attaches the report.

**Why:** Optional operator workflow; IAM policy in README is **customer-side** least-privilege example (`support:CreateCase`, attachments only).

**Not in repo:** No embedded credentials. Uses ambient AWS CLI config on the host.

---

## Deep mode disk writes

**Design:** `-m deep` runs `dd` read/write tests (~1 GB write) for disk characterization.

**Why:** Explicit deep mode; documented performance impact in README.

---

## Hardening already in tree (not exceptions)

| Prior CSE finding | Current behavior |
|-------------------|------------------|
| Sourcing `/etc/os-release` | **Fixed** — `read_os_release_field()` parses without sourcing |
| Predictable report filename | **Fixed** — `mktemp` + `chmod 600` in `validate_and_init_output()` |
| Temp work dir | `mktemp -d` under `/tmp/linux-forensics.work.XXXXXX`, mode 700 |

Re-run internal snapshot scan to confirm closure.

---

## Example IAM in README

README includes a **template** IAM policy JSON for AWS Support. It is documentation, not a deployed role in this repo.
