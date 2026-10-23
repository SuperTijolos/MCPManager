# Build from the repository root so the shared package is in the context:
#   docker build -f server/Dockerfile -t mcp-portal .
FROM dart:stable AS build
WORKDIR /app
COPY packages/mcp_core packages/mcp_core
COPY server server
WORKDIR /app/server
RUN dart pub get
RUN dart compile exe bin/mcp_portal.dart -o /app/mcp_portal
RUN mkdir -p /data

# Nothing but the compiled program and the runtime libraries it needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/mcp_portal /app/mcp_portal
COPY --from=build --chown=10001:10001 /data /data

ENV PORTAL_HOST=0.0.0.0 \
    PORTAL_PORT=8787 \
    PORTAL_DATA_DIR=/data
USER 10001:10001
VOLUME /data
EXPOSE 8787
ENTRYPOINT ["/app/mcp_portal"]
