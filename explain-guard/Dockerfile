# The library must be built against the exact timescale image it is loaded into.
ARG TIMESCALE_IMAGE

FROM ${TIMESCALE_IMAGE} AS build

USER root
WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libc6-dev make \
    && major=$(pg_config --version | sed -E 's/^PostgreSQL ([0-9]+).*/\1/') \
    && apt-get download "postgresql-server-dev-$major=$(dpkg-query -W -f='${Version}' "postgresql-$major")" \
    && dpkg -x postgresql-server-dev-*.deb /

COPY Makefile wb_explain_guard.c ./

RUN make with_llvm=no

FROM busybox:1.37.0

LABEL org.opencontainers.image.source="https://github.com/wirenboard/cloud-on-premise"
LABEL org.opencontainers.image.description="wb_explain_guard library for the stock TimescaleDB image"
LABEL org.opencontainers.image.licenses="PostgreSQL"

COPY --from=build /build/wb_explain_guard.so /wb_explain_guard.so
COPY LICENSE /LICENSE

# Rename instead of overwriting: a running postgres keeps the old file mapped.
CMD ["sh", "-c", "cp /wb_explain_guard.so /out/.wb_explain_guard.so.new && mv -f /out/.wb_explain_guard.so.new /out/wb_explain_guard.so"]
