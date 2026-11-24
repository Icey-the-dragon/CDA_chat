# No npm install: the demo server uses only Node builtins, so the image is
# small and builds in seconds even without network access to a registry cache.
FROM node:22-alpine

WORKDIR /app
COPY server.mjs load.mjs index.html ./

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.mjs"]
