# ironlog-grafana — see images/README.md for the contract.
# Build context is the repository root:
#   docker build -f images/grafana/Dockerfile -t ironlog-grafana .
ARG GRAFANA_VERSION=13.3.0
FROM docker.io/grafana/grafana:${GRAFANA_VERSION}

ARG TARGETARCH

USER root

# --- ClickHouse plugin, baked OUTSIDE /var/lib/grafana ----------------------
# Version comes from the single pin file the AMI scripts also use. `grafana
# cli` runs in the target-platform stage, so it downloads the build for that
# architecture; the check below fails the build if the matching backend binary
# is not in the result.
COPY scripts/ami/grafana-clickhouse-plugin.version /tmp/plugin.version
ENV GF_PATHS_PLUGINS=/usr/share/ironlog/grafana-plugins
RUN set -eu; \
    v="$(tr -d '[:space:]' < /tmp/plugin.version)"; \
    case "$v" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "bad plugin pin: $v" >&2; exit 1;; esac; \
    mkdir -p "$GF_PATHS_PLUGINS"; \
    /usr/share/grafana/bin/grafana cli --pluginsDir "$GF_PATHS_PLUGINS" plugins install grafana-clickhouse-datasource "$v"; \
    d="$GF_PATHS_PLUGINS/grafana-clickhouse-datasource"; \
    grep -Eq "\"version\"[[:space:]]*:[[:space:]]*\"$v\"" "$d/plugin.json"; \
    ls "$d"; \
    test -f "$d/gpx_clickhouse_linux_${TARGETARCH}"; \
    chmod 0755 "$d"/gpx_clickhouse_linux_*; \
    chgrp -R 0 "$GF_PATHS_PLUGINS"; chmod -R g=u,a+rX "$GF_PATHS_PLUGINS"; \
    rm -f /tmp/plugin.version

# --- Provisioning ---------------------------------------------------------
# Grafana provisioning has no ${VAR:-default} syntax (only $VAR / ${VAR}), so
# the datasource host/port are rewritten to ${...} references here and the
# defaults live in the ENV below. The repo file stays untouched for Compose.
COPY grafana/provisioning/ /etc/grafana/provisioning/
RUN set -eu; \
    f=/etc/grafana/provisioning/datasources/clickhouse.yml; \
    sed -i -E 's/^([[:space:]]+host:[[:space:]]*)clickhouse[[:space:]]*$/\1${IRONLOG_CLICKHOUSE_HOST}/; s/^([[:space:]]+port:[[:space:]]*)9000[[:space:]]*$/\1${IRONLOG_CLICKHOUSE_NATIVE_PORT}/' "$f"; \
    test "$(grep -c 'host: ${IRONLOG_CLICKHOUSE_HOST}' "$f")" = 2; \
    test "$(grep -c 'port: ${IRONLOG_CLICKHOUSE_NATIVE_PORT}' "$f")" = 2; \
    chgrp -R 0 /etc/grafana/provisioning; chmod -R g=u /etc/grafana/provisioning


ENV IRONLOG_CLICKHOUSE_HOST=clickhouse \
    IRONLOG_CLICKHOUSE_NATIVE_PORT=9000 \
    GF_PLUGINS_PREINSTALL_DISABLED=true \
    GF_AUTH_DISABLE_LOGIN_FORM=false \
    GF_AUTH_BASIC_ENABLED=true \
    GF_AUTH_ANONYMOUS_ENABLED=false \
    GF_USERS_ALLOW_SIGN_UP=false \
    GF_AUTH_GENERIC_OAUTH_ENABLED=false \
    GF_SECURITY_X_XSS_PROTECTION=false

# Upstream already makes /var/lib/grafana group-0 writable; keep g=u. Grafana
# writes its files 0640, so a reused volume needs the same UID (as OpenShift gives).
RUN chgrp -R 0 /var/lib/grafana && chmod -R g=u /var/lib/grafana

USER 472
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:3000/api/health || exit 1
