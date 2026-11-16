FROM node:24-alpine AS builder

WORKDIR /app

COPY package*.json ./
RUN npm config set maxsockets 1
RUN npm install
RUN npm ci

COPY . .
RUN npm run generate
RUN npm run build

FROM node:24-alpine AS release

WORKDIR /app

# Patch Alpine packages (e.g. zlib) and drop unused npm/yarn from the Node image
# so the runtime does not ship their vulnerable transitive dependencies.
RUN apk upgrade --no-cache && apk add --no-cache tzdata
ENV TZ=Europe/Berlin

COPY --from=builder /app/dist /app/dist
COPY --from=builder /app/package*.json ./

ENV NODE_ENV=production
RUN npm ci --ignore-scripts --omit=dev \
    && npm cache clean --force \
    && rm -rf \
      /usr/local/lib/node_modules/npm \
      /usr/local/lib/node_modules/corepack \
      /usr/local/bin/npm \
      /usr/local/bin/npx \
      /usr/local/bin/corepack \
      /opt/yarn-v* \
      /usr/local/bin/yarn \
      /usr/local/bin/yarnpkg

ENTRYPOINT ["node", "dist/index.js"]
