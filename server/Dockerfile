# Build from the repository root so the shared package is in the context:
#   docker build -f server/Dockerfile -t mcp-portal .
FROM dart:stable AS build
WORKDIR /app
COPY packages/mcp_core packages/mcp_core
COPY server server
COPY migrations migrations
WORKDIR /app/server
RUN dart pub get
RUN dart compile exe bin/mcp_portal.dart -o /app/mcp_portal

# Nothing but the compiled program and the runtime libraries it needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/mcp_portal /app/mcp_portal
COPY --from=build /app/migrations /app/migrations

ENV PORTAL_HOST=0.0.0.0 \
    PORTAL_PORT=8787 \
    PORTAL_MIGRATIONS_DIR=/app/migrations
USER 10001:10001
EXPOSE 8787
ENTRYPOINT ["/app/mcp_portal"]
