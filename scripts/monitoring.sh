#!/usr/bin/env bash
#
# Monitoring stage — publish the scrape config and alert rules, reload
# Prometheus, and confirm it is actually observing production.
#
# Keeping this in the pipeline rather than doing it by hand once means an alert
# rule is reviewed, versioned and deployed like any other change, and a broken
# rule file fails a build instead of silently leaving nothing watching.
#
#   ./scripts/monitoring.sh
#
set -euo pipefail

PROMETHEUS_URL="http://127.0.0.1:9090"
MONITORING_DIR="${HOME}/taskmaster-deploy/monitoring"
PROD_JOB="taskmaster-prod"

cd "$(dirname "$0")/.."

if ! command -v promtool >/dev/null 2>&1; then
    echo "ERROR: promtool not found — install with: brew install prometheus" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Validate before publishing.
#
# Prometheus keeps running its previous rules if a reload fails, so an invalid
# file would otherwise leave monitoring silently stale rather than broken.
# ---------------------------------------------------------------------------
echo "==> Validating Prometheus configuration"
promtool check config monitoring/prometheus.yml

# ---------------------------------------------------------------------------
# 2. Publish to a stable path.
#
# Prometheus is a long-lived service and cannot read from the Jenkins
# workspace, which is transient and may be wiped between builds.
# ---------------------------------------------------------------------------
mkdir -p "$MONITORING_DIR"
cp monitoring/prometheus.yml monitoring/alerts.yml "$MONITORING_DIR/"
echo "==> Published config to ${MONITORING_DIR}"

# ---------------------------------------------------------------------------
# 3. Reload, then wait for Prometheus to come back.
# ---------------------------------------------------------------------------
if ! curl -fsS --max-time 10 -X POST "${PROMETHEUS_URL}/-/reload" >/dev/null 2>&1; then
    echo "ERROR: could not reload Prometheus at ${PROMETHEUS_URL}" >&2
    echo "       Is it running? brew services start prometheus" >&2
    exit 1
fi
echo "==> Reloaded Prometheus"

# ---------------------------------------------------------------------------
# 4. Confirm the alert rules are loaded.
# ---------------------------------------------------------------------------
echo "==> Alert rules"
python3 scripts/check_monitoring.py rules "$PROMETHEUS_URL"

# ---------------------------------------------------------------------------
# 5. Confirm production is actually being scraped.
#
# A green pipeline with nothing watching production is the failure this guards
# against. Prometheus may need a scrape interval to pick up a service that has
# only just been released, so allow a short grace period.
# ---------------------------------------------------------------------------
echo "==> Checking Prometheus can see ${PROD_JOB}"
SCRAPED=""
for _ in $(seq 1 12); do
    if python3 scripts/check_monitoring.py scraped "$PROMETHEUS_URL" "$PROD_JOB" >/dev/null 2>&1; then
        SCRAPED="yes"
        break
    fi
    sleep 5
done

if [ -z "$SCRAPED" ]; then
    echo "ERROR: Prometheus is not successfully scraping ${PROD_JOB}" >&2
    python3 scripts/check_monitoring.py scraped "$PROMETHEUS_URL" "$PROD_JOB" >&2 || true
    echo "       Check ${PROMETHEUS_URL}/targets" >&2
    exit 1
fi

python3 scripts/check_monitoring.py scraped "$PROMETHEUS_URL" "$PROD_JOB"
echo "==> Monitoring OK"
