# syntax=docker/dockerfile:1.7
# Required: official release plus a reviewed immutable manifest digest.
ARG KEYCLOAK_IMAGE
FROM ${KEYCLOAK_IMAGE} AS builder
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true
WORKDIR /opt/keycloak
RUN /opt/keycloak/bin/kc.sh build

FROM ${KEYCLOAK_IMAGE}
ENV KC_DB=postgres \
    KC_DB_SCHEMA=keycloak \
    KC_HEALTH_ENABLED=true \
    KC_METRICS_ENABLED=true \
    KC_HOSTNAME_STRICT=true \
    KC_HTTP_ENABLED=true \
    KC_HTTP_MANAGEMENT_PORT=9000 \
    KC_HTTP_MANAGEMENT_SCHEME=http \
    KC_PROXY_HEADERS=xforwarded \
    KC_CACHE=ispn \
    KC_CACHE_STACK=jdbc-ping \
    KC_LOG=console \
    KC_LOG_CONSOLE_OUTPUT=json
COPY --from=builder --chown=1000:0 /opt/keycloak/ /opt/keycloak/
COPY --chown=1000:0 --chmod=0444 realm-template.json /opt/keycloak/data/import/vortexbird-realm.json
COPY --chown=1000:0 --chmod=0444 rds-ca-bundle.pem /opt/keycloak/conf/rds-ca-bundle.pem
COPY --chown=1000:0 --chmod=0555 entrypoint.sh validate-runtime.sh healthcheck.sh /opt/keycloak/bin/
USER 1000
EXPOSE 8080 9000 7800 57800
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 CMD ["/opt/keycloak/bin/healthcheck.sh"]
ENTRYPOINT ["/opt/keycloak/bin/entrypoint.sh"]
CMD ["start", "--optimized", "--import-realm"]
