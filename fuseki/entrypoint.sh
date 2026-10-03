#!/bin/sh
set -eu

: "${ADMIN_PASSWORD:?ADMIN_PASSWORD must be set}"

# Render shiro.ini into FUSEKI_BASE, where Fuseki looks for it.
sed "s|\${ADMIN_PASSWORD}|${ADMIN_PASSWORD}|" /opt/fuseki/shiro.ini > "$FUSEKI_BASE/shiro.ini"

exec java $JAVA_OPTIONS -jar /opt/fuseki/fuseki-server.jar --config=/opt/fuseki/config.ttl "$@"
