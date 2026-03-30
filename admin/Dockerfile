# Build React SPA
FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# Serve via nginx
FROM nginx:1.27-alpine
LABEL org.opencontainers.image.source=https://github.com/molkex/chameleon
COPY --from=builder /app/dist /usr/share/nginx/html/admin
# nginx.conf is mounted from backend/nginx.conf via docker-compose
EXPOSE 80
