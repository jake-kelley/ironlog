# ironlog-clickhouse — build context is the repository root.
# Config, lockdown, DDL and the ironlog-schema command are baked in; behavior
# is selected only by the environment variables in images/README.md.
ARG CLICKHOUSE_IMAGE=docker.io/clickhouse/clickhouse-server:26.8.34.13
FROM ${CLICKHOUSE_IMAGE}

# Upstream ships config.d/docker_related_config.xml (listen '::' + 0.0.0.0).
# Replaced by images/clickhouse/05-listen.xml so listen_host follows
# IRONLOG_CLICKHOUSE_LISTEN. 10-query-log.xml and the lockdown are the repo files.
COPY images/clickhouse/05-listen.xml /etc/clickhouse-server/config.d/05-listen.xml
COPY clickhouse/config.d/10-query-log.xml /etc/clickhouse-server/config.d/10-query-log.xml
COPY clickhouse/users.d/00-lockdown.xml /etc/clickhouse-server/users.d/00-lockdown.xml
COPY clickhouse/ddl/ /ddl/
COPY images/clickhouse/entrypoint.sh /usr/local/bin/ironlog-entrypoint
COPY images/clickhouse/ironlog-schema.sh /usr/local/bin/ironlog-schema
COPY images/clickhouse/healthcheck.sh /usr/local/bin/ironlog-healthcheck
COPY images/clickhouse/allowed-hosts.sh /usr/local/bin/ironlog-allowed-hosts

# Non-root, GID 0 with g=u so a random UID with GID 0 works. config.d and
# users.d must stay writable: the entrypoint writes users.d/default-user.xml and
# config.d/20-storage-s3.xml at start.
ENV IRONLOG_CLICKHOUSE_LISTEN=0.0.0.0
RUN rm -f /etc/clickhouse-server/config.d/docker_related_config.xml \
 && chmod 0755 /usr/local/bin/ironlog-healthcheck /usr/local/bin/ironlog-entrypoint /usr/local/bin/ironlog-schema /usr/local/bin/ironlog-allowed-hosts \
 && chmod 0644 /etc/clickhouse-server/config.d/*.xml /etc/clickhouse-server/users.d/*.xml \
 && chmod -R a+rX /ddl \
 && chown -R 10001:0 /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server \
 && chmod -R g=u /var/lib/clickhouse /var/log/clickhouse-server /etc/clickhouse-server

USER 10001:0
VOLUME /var/lib/clickhouse
EXPOSE 8123 9000
HEALTHCHECK --interval=15s --timeout=5s --retries=10 --start-period=60s \
  CMD ["/usr/local/bin/ironlog-healthcheck"]
ENTRYPOINT ["/usr/local/bin/ironlog-entrypoint"]
