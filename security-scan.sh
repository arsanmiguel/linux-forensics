#!/usr/bin/env bash
# CSE / internal security scan for linux-forensics (local Docker tools + optional shellcheck).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${SECURITY_SCAN_OUT:-/tmp/linux-forensics-security-scan}"
DOCKER_HOST="${DOCKER_HOST:-unix://${HOME}/.colima/default/docker.sock}"
export DOCKER_HOST
export DOCKER_CONFIG="${DOCKER_CONFIG:-/tmp/docker-nocreds}"
mkdir -p "$OUT" "$DOCKER_CONFIG"
[[ -f "${DOCKER_CONFIG}/config.json" ]] || printf '%s\n' '{"auths":{}}' > "${DOCKER_CONFIG}/config.json"

if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker unavailable (start Colima: colima start)" >&2
  exit 1
fi

echo "=== Gitleaks (git history) ===" | tee "$OUT/latest-gitleaks.txt"
docker run --rm -v "${ROOT}:/repo:ro" -w /repo zricethezav/gitleaks:v8.30.1 \
  detect --redact --source /repo 2>&1 | tee -a "$OUT/latest-gitleaks.txt" || true

echo "=== Trivy (repo secrets) ===" | tee "$OUT/latest-trivy-script.txt"
docker run --rm -v "${ROOT}:/repo:ro" -w /repo aquasec/trivy:0.71.2 fs \
  --scanners secret \
  --severity HIGH,CRITICAL,MEDIUM \
  . 2>&1 | tee -a "$OUT/latest-trivy-script.txt" || true

if command -v shellcheck >/dev/null 2>&1; then
  echo "=== shellcheck ===" | tee "$OUT/latest-shellcheck.txt"
  shellcheck -x "${ROOT}/invoke-linux-forensics.sh" 2>&1 | tee -a "$OUT/latest-shellcheck.txt" || true
else
  echo "SKIP shellcheck (brew install shellcheck)" | tee "$OUT/latest-shellcheck.txt"
fi

echo ""
echo "Reports in ${OUT}"
echo "Documented exceptions: SECURITY-EXCEPTIONS.md"
echo "Prior Amazon Git Security Scanner config: .security-scan/config.yaml (local CSE init)"
