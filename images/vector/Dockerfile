# ironlog-vector — build context is the repository root.
# One image, two roles chosen at runtime by IRONLOG_VECTOR_ROLE=hosts|aws.
ARG VECTOR_IMAGE=docker.io/timberio/vector:0.61.0-debian
FROM ${VECTOR_IMAGE}

COPY vector/hosts.yaml vector/vector.yaml vector/tests.yaml vector/tests-hosts.yaml /etc/vector/
COPY images/vector/entrypoint.sh /usr/local/bin/ironlog-entrypoint
COPY images/vector/healthcheck.sh /usr/local/bin/ironlog-healthcheck

# Our configs read secrets and addresses from the environment (Vector >=0.57
# disables that by default). Non-root, GID 0 g=u so a random UID with GID 0 works.
ENV VECTOR_DANGEROUSLY_ALLOW_ENV_VAR_INTERPOLATION=true \
    VECTOR_LOG=info
RUN chmod 0755 /usr/local/bin/ironlog-entrypoint /usr/local/bin/ironlog-healthcheck \
 && chmod 0644 /etc/vector/*.yaml \
 && useradd --uid 10001 --gid 0 --no-create-home --home-dir /var/lib/vector --shell /usr/sbin/nologin vector \
 && chown -R 10001:0 /var/lib/vector \
 && chmod -R g=u /var/lib/vector

USER 10001:0
VOLUME /var/lib/vector
EXPOSE 8088 6000 8686
HEALTHCHECK --interval=15s --timeout=5s --retries=5 CMD ["/usr/local/bin/ironlog-healthcheck"]
ENTRYPOINT ["/usr/local/bin/ironlog-entrypoint"]
