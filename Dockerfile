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

RUN apk add --no-cache tzdata
ENV TZ=Europe/Berlin

COPY --from=builder /app/dist /app/dist
COPY --from=builder /app/package*.json ./

ENV NODE_ENV=production
RUN npm ci --ignore-scripts --omit=dev

ENTRYPOINT ["node", "dist/index.js"]
