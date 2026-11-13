# Warrantra backend — one image for both processes:
#   API:    docker run ... warrantra-backend                      (default)
#   Worker: docker run -e PROCESS_TYPE=worker ... warrantra-backend
# Configuration comes only from environment variables (never bake .env into the image).

FROM node:22-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npx tsc -p tsconfig.json

FROM node:22-slim AS runtime
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY docs/openapi.json ./docs/openapi.json
COPY supabase ./supabase
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD [ "$PROCESS_TYPE" = "worker" ] || node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
# PROCESS_TYPE=worker runs the job worker; anything else runs the API.
CMD ["sh", "-c", "if [ \"$PROCESS_TYPE\" = \"worker\" ]; then exec node dist/workers/run.js; else exec node dist/server.js; fi"]
