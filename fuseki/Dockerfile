FROM eclipse-temurin:21-jre

ARG JENA_VERSION=6.2.0
ARG MAVEN_REPO=https://repo1.maven.org/maven2

ENV FUSEKI_HOME=/opt/fuseki \
    FUSEKI_BASE=/fuseki \
    JAVA_OPTIONS="-Xmx2g"

RUN set -eux; \
    mkdir -p "$FUSEKI_HOME" "$FUSEKI_BASE/databases"; \
    jar="jena-fuseki-server-${JENA_VERSION}.jar"; \
    url="${MAVEN_REPO}/org/apache/jena/jena-fuseki-server/${JENA_VERSION}/${jar}"; \
    curl -fsSL -o "$FUSEKI_HOME/fuseki-server.jar" "$url"; \
    curl -fsSL "$url.sha1" | awk '{print $1"  '"$FUSEKI_HOME"'/fuseki-server.jar"}' | sha1sum -c -

COPY config.ttl shiro.ini /opt/fuseki/
COPY --chmod=755 entrypoint.sh /opt/fuseki/entrypoint.sh

WORKDIR /fuseki
VOLUME /fuseki/databases
EXPOSE 3030

ENTRYPOINT ["/opt/fuseki/entrypoint.sh"]
