FROM node:24-alpine
WORKDIR /app
RUN mkdir -p /data && chown node:node /data
COPY --chown=node:node package.json server.mjs offers.mjs analytics.mjs ./
COPY --chown=node:node public ./public
USER node
ENV HOST=0.0.0.0 PORT=7341 STORAGE_DIR=/data
EXPOSE 7341
CMD ["node", "server.mjs"]
