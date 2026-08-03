FROM node:22-alpine

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY firehose-sidecar.js ./
COPY proto ./proto

USER node

CMD ["node", "firehose-sidecar.js"]
