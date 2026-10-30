# ---- Stage 1: build the static files ----
FROM node:24-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
# Empty = the browser calls /api/v1 on the same host that served the page (nginx proxies it).
ARG VITE_API_URL=
ENV VITE_API_URL=$VITE_API_URL
RUN npm run build

# ---- Stage 2: nginx serves dist/ and proxies /api to the backend ----
FROM nginx:1.28-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 80
