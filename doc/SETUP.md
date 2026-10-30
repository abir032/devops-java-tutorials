# Setup Guide

How to run Order Desk (React frontend + Spring Boot backend + MariaDB, Redis and RabbitMQ) in
three ways, with every command explained:

- [A. Manual setup (no Docker for the app)](#a-manual-setup-development): the app runs directly on the host, the three data services run as throwaway containers. Best for development.
- [B. Docker, by hand](#b-docker-by-hand): every container, network and volume created with `docker` commands. Best for learning what Compose does for you.
- [C. Docker Compose](#c-docker-compose): the whole stack from `docker-compose.yml` with one command. The normal way to run it.

Contents:

1. [Architecture](#1-architecture)
2. [Prerequisites](#2-prerequisites)
3. [Configuration files](#3-configuration-files)
4. [A. Manual setup (development)](#a-manual-setup-development)
5. [B. Docker, by hand](#b-docker-by-hand)
6. [C. Docker Compose](#c-docker-compose)
7. [Accessing the app from your laptop](#7-accessing-the-app-from-your-laptop)
8. [Day-to-day operations](#8-day-to-day-operations)
9. [Troubleshooting](#9-troubleshooting)
10. [Security notes](#10-security-notes)

> Commands are shown without `sudo`. If your user is not in the `docker` group, prefix
> `docker ...` with `sudo`.

---

## 1. Architecture

### 1.1 Components

| Component | Technology | What it does |
| --- | --- | --- |
| **frontend** | React 19 + TypeScript (Vite) served by nginx 1.28 | Serves the static app **and** proxies `/api/` to the backend. The only public entry point. |
| **backend** | Spring Boot 4, Java 21 | REST API at `/api/v1`, RabbitMQ listener, Actuator health. Stateless, so it can run as several replicas. |
| **db** | MariaDB 11.8 | `products` and `orders` tables (schema by Flyway). Data lives in the `db-data` volume. |
| **redis** | Redis 7 | Cache of the product list (disposable). |
| **rabbitmq** | RabbitMQ 4 | Queue that carries new orders from the API to the listeners. |

### 1.2 Docker architecture (options B and C)

```
              Your laptop browser
                     │  http://<server>:8080  (or an SSH tunnel, see section 7)
                     ▼
 ┌──────────────────────── EC2 host ─────────────────────────────────────┐
 │   host :8080                                                          │
 │      │                                                                │
 │ ┌────┼──────────── web-net (bridge) ───────────────────────────────┐  │
 │ │    ▼                                                             │  │
 │ │ ┌──────────┐   /api/*    ┌───────────┐  ┌───────────┐           │  │
 │ │ │ frontend │────────────►│ backend-1 │  │ backend-2 │           │  │
 │ │ │ nginx:80 │ DNS name    │   :8080   │  │   :8080   │           │  │
 │ │ └──────────┘ "backend"   └─────┬─────┘  └─────┬─────┘           │  │
 │ │  static files + proxy          │              │                 │  │
 │ └────────────────────────────────┼──────────────┼─────────────────┘  │
 │ ┌────────────── data-net (internal: no outside access) ───────────┐  │
 │ │                                │              │                 │  │
 │ │            ┌───────────────────┼──────────────┼──────┐          │  │
 │ │            ▼ "db"              ▼ "redis"      ▼ "rabbitmq"      │  │
 │ │      ┌──────────┐       ┌──────────┐    ┌──────────┐           │  │
 │ │      │ MariaDB  │       │  Redis   │    │ RabbitMQ │           │  │
 │ │      │  :3306   │       │  :6379   │    │  :5672   │           │  │
 │ │      └────┬─────┘       └──────────┘    └──────────┘           │  │
 │ └───────────┼─────────────────────────────────────────────────────┘  │
 │             ▼                                                        │
 │   volume: db-data (/var/lib/mysql)                                   │
 └───────────────────────────────────────────────────────────────────────┘
```

Both networks are Docker **bridge** networks, but they are **not connected to each other**. The
backend containers have an interface on each and are the only link between the public side and
the data side.

### 1.3 Request flow

1. The browser opens `http://<server>:8080` and gets the HTML/JS/CSS from the **frontend** container (nginx).
2. The JavaScript calls `/api/v1/...` on the **same host and port**. `VITE_API_URL` is empty at
   build time, so the path is relative. There is no CORS check because the origin is the same.
3. nginx matches `location /api/` and forwards the request to `http://backend:8080`. Docker's DNS
   returns the IP of every backend replica, so requests are spread over them.
4. The backend answers:
   - `GET /products`: from Redis if cached (`X-Cache: HIT`), otherwise from MariaDB (`MISS`).
   - `POST /orders`: saves the order as `PENDING` in MariaDB, publishes `{orderId}` to RabbitMQ and returns `202`.
5. A listener in **one** of the backends takes the message, waits 3 s, updates stock and sets the
   order to `CONFIRMED` or `FAILED`. `processedBy` shows which replica did it.
6. The backend reaches the data services by name (`db`, `redis`, `rabbitmq`) over **data-net**.

### 1.4 Design decisions

| Decision | Why |
| --- | --- |
| **Two networks, `data-net` is `internal`** | MariaDB, Redis and RabbitMQ are reachable *only* from the backend. An internal network has no route out and Docker never publishes ports on it, so the data tier cannot be exposed by accident. |
| **Backend joins both networks** | It must accept traffic from the frontend (`web-net`) and reach the data services (`data-net`). It is the only bridge between them. |
| **The frontend never joins `data-net`** | Even a compromised frontend cannot resolve or reach the database. |
| **Only the frontend publishes a port** | One public entry point. The backend has no `-p`, and its `/actuator` endpoints are not proxied, so they stay private. |
| **nginx serves the files and proxies `/api`** | Same origin: no CORS, no URL baked into the JavaScript, no separate load balancer container. |
| **Containers find each other by name, never `localhost`** | Inside a container `localhost` is the container itself. Docker's DNS (`127.0.0.11`) resolves names on user-defined networks. |
| **nginx resolves `backend` per request** | `proxy_pass` uses a variable plus `resolver ... valid=10s`, so replicas that are added, removed or recreated are picked up within 10 s, and nginx starts even if the backend isn't up yet. |
| **Stateless backend + replicas** | State lives in MariaDB/Redis/RabbitMQ. All replicas consume the same queue (competing consumers), and a row lock on the product stops two of them selling the last item. |
| **Environment variables, no edited config** | Spring maps `SPRING_DATASOURCE_URL` to `spring.datasource.url` and so on. The same jar runs everywhere. |
| **Multi-stage Dockerfiles** | The build tools (Maven, Node) stay in a throw-away stage. The runtime images hold only a JRE + jar, or nginx + static files. |
| **Non-root backend** | The backend runs as `appuser`. |
| **Healthchecks + `depends_on: service_healthy`** | Flyway and the RabbitMQ listener need their services at startup. Compose waits until each reports healthy. |

### 1.5 Ports

| Port | Where | Used by |
| --- | --- | --- |
| 5173 | host | Vite dev server (option A) |
| 8080 | host (A) | Option A: Spring Boot |
| 8080 | host (B/C) | Frontend nginx (container port 80). The backend's own 8080 exists only inside `web-net`. |
| 3306, 6379, 5672, 15672 | host (A) / `data-net` only (B/C) | MariaDB, Redis, RabbitMQ, RabbitMQ management UI |

### 1.6 Files involved

| File | Purpose | Committed? |
| --- | --- | --- |
| `docker-compose.yml` | Defines the whole stack for option C | yes |
| `backend/Dockerfile`, `backend/.dockerignore` | Backend image (Maven build, then JRE) | yes |
| `frontend/Dockerfile`, `frontend/.dockerignore` | Frontend image (Node build, then nginx) | yes |
| `frontend/nginx.conf` | Static files + `/api` proxy | yes |
| `.env.db` | MariaDB passwords for the `db` container (B/C) | **no** (gitignored) |
| `backend/.env.docker` | Backend settings for B/C (hosts `db`, `redis`, `rabbitmq`) | **no** (gitignored) |
| `backend/.env`, `frontend/.env` | Settings for option A | **no** (gitignored) |
| `.env.db.example`, `backend/.env.docker.example`, `*/.env.example` | Templates | yes |

---

## 2. Prerequisites

| Tool | Needed for | Check |
| --- | --- | --- |
| JDK 21 | Option A (the Docker build brings its own) | `java -version` |
| Node.js 24 + npm | Option A | `node --version` |
| Docker Engine + Compose plugin | All options (A needs it for the data services) | `docker --version`, `docker compose version` |

Docker install: <https://docs.docker.com/engine/install/ubuntu/>. To run `docker` without `sudo`:
`sudo usermod -aG docker "$USER"`, then log out and back in.

---

## 3. Configuration files

Real env files are secret and gitignored. Create them once.

**Generate passwords** without characters that need escaping:

```bash
openssl rand -base64 24 | tr -d '/+='
```

### 3.1 `.env.db` (repo root, options B/C)

Read by the MariaDB container **only the first time it starts on an empty volume** (see
[Access denied](#access-denied-for-user-orderdesk)).

```bash
cp .env.db.example .env.db      # then replace the placeholders
chmod 600 .env.db               # readable by your user only
```

```dotenv
MARIADB_ROOT_PASSWORD=<root-password>
MARIADB_DATABASE=orderdesk
MARIADB_USER=orderdesk
MARIADB_PASSWORD=<app-password>
```

| Variable | Effect on first start |
| --- | --- |
| `MARIADB_ROOT_PASSWORD` | Password for the `root` account. |
| `MARIADB_DATABASE` | Creates this database. |
| `MARIADB_USER` / `MARIADB_PASSWORD` | Creates this user with all rights on that database only. The backend uses it. |

### 3.2 `backend/.env.docker` (options B/C)

```bash
cp backend/.env.docker.example backend/.env.docker
chmod 600 backend/.env.docker
```

```dotenv
SPRING_DATASOURCE_URL=jdbc:mariadb://db:3306/orderdesk
SPRING_DATASOURCE_USERNAME=orderdesk
SPRING_DATASOURCE_PASSWORD=<app-password>
SPRING_DATA_REDIS_HOST=redis
SPRING_RABBITMQ_HOST=rabbitmq
SPRING_RABBITMQ_USERNAME=guest
SPRING_RABBITMQ_PASSWORD=guest
```

| Variable | Meaning |
| --- | --- |
| `SPRING_DATASOURCE_URL` | JDBC URL. The host is **`db`**, the container's name on `data-net`. |
| `SPRING_DATASOURCE_USERNAME/PASSWORD` | Must equal `MARIADB_USER` / `MARIADB_PASSWORD` in `.env.db`. |
| `SPRING_DATA_REDIS_HOST` | Container name **`redis`**. |
| `SPRING_RABBITMQ_HOST/USERNAME/PASSWORD` | Container name **`rabbitmq`**. `guest/guest` is fine because the broker is on an internal network only. |

You don't need `APP_CORS_ALLOWED_ORIGINS`: the browser and the API share one origin.
Anything you leave out falls back to the `localhost` defaults in `application.properties`, which is
the cause of the most common error in [Troubleshooting](#connection-refused-to-localhost3306-in-the-backend-logs).

### 3.3 `backend/.env` and `frontend/.env` (option A)

Spring does not read `.env` files itself; export the variables or rely on the `localhost`
defaults, which already match option A. For the frontend:

```bash
cp frontend/.env.example frontend/.env     # VITE_API_URL=http://localhost:8080
```

`VITE_API_URL` is the address the **browser** calls in dev. The Docker builds ignore this file
(`frontend/.dockerignore`) and use an empty value instead.

---

## A. Manual setup (development)

Everything runs on the host, except the three data services, which run as throwaway containers.

### A.1 Start MariaDB, Redis and RabbitMQ

```bash
docker run -d --rm --name od-db -p 3306:3306 \
  -e MARIADB_DATABASE=orderdesk -e MARIADB_USER=orderdesk \
  -e MARIADB_PASSWORD=orderdesk -e MARIADB_ROOT_PASSWORD=root mariadb:11
docker run -d --rm --name od-redis -p 6379:6379 redis:7
docker run -d --rm --name od-mq -p 5672:5672 -p 15672:15672 rabbitmq:4-management
```

- `--rm` deletes the container (and its data) when it stops.
- `-p HOST:CONTAINER` publishes the port on the host so the app can use `localhost`.
- Credentials are `orderdesk/orderdesk`, the same as the defaults in `application.properties`.

### A.2 Run the backend

```bash
cd backend && ./mvnw spring-boot:run
```

Flyway creates the tables and seeds 5 products on the first start. Check
<http://localhost:8080/actuator/health>.

### A.3 Run the frontend

```bash
cd frontend && cp .env.example .env && npm install && npm run dev
```

Open <http://localhost:5173>. The backend allows this origin through `app.cors.allowed-origins`.

### A.4 Stop

`Ctrl+C` both, then `docker stop od-db od-redis od-mq`.

> **Before option B or C:** stop these (`docker stop od-db od-redis od-mq`). B and C start their own
> data services on a private network, and nothing from these throwaway containers is reused.

---

## B. Docker, by hand

This builds exactly what `docker-compose.yml` defines, one command at a time. Run everything from
the **repo root**.

> Run option B **or** option C, not both. They publish the same host port (8080) and use the same
> container names.

### B.1 Create the networks

```bash
docker network create web-net
docker network create --internal data-net
```

- `web-net` is a user-defined **bridge**: containers on it resolve each other by name, and their ports can be published.
- `--internal` makes `data-net` isolated: no route out, no published ports. Only containers attached to it can reach the data services.

Verify: `docker network inspect data-net --format '{{.Name}} internal={{.Internal}}'`.

### B.2 Create the volume

```bash
docker volume create db-data
```

A named volume managed by Docker. MariaDB keeps its files there, so the data survives removing
the container.

### B.3 Start the data services

Create `.env.db` first ([section 3.1](#31-envdb-repo-root-options-bc)).

```bash
docker run -d --name db --network data-net \
  --env-file .env.db \
  -v db-data:/var/lib/mysql \
  --health-cmd "healthcheck.sh --connect --innodb_initialized" \
  --health-interval 5s --health-timeout 5s --health-retries 10 \
  --restart unless-stopped \
  mariadb:11.8

docker run -d --name redis --network data-net \
  --health-cmd "redis-cli ping" --health-interval 5s --health-timeout 3s --health-retries 10 \
  --restart unless-stopped \
  redis:7

docker run -d --name rabbitmq --network data-net \
  --health-cmd "rabbitmq-diagnostics -q ping" \
  --health-interval 10s --health-timeout 10s --health-retries 10 \
  --restart unless-stopped \
  rabbitmq:4
```

| Flag | Explanation |
| --- | --- |
| `-d` | Detached: run in the background. |
| `--name db` | Container name, which is also its **DNS name** on the network. The backend connects to host `db`. |
| `--network data-net` | Attach **only** to the internal network. |
| `--env-file .env.db` | Load `MARIADB_*`. On an **empty** volume, the entrypoint uses them to create root, the database and the app user. |
| `-v db-data:/var/lib/mysql` | Mount the volume at MariaDB's data directory. |
| `--health-cmd ...` | Command Docker runs periodically to judge health. `healthcheck.sh` is **inside the mariadb image** (`/usr/local/bin/healthcheck.sh`), as are `redis-cli` and `rabbitmq-diagnostics` in their images. |
| `--health-interval/-timeout/-retries` | Run the check every N seconds, fail after the timeout, report `unhealthy` after N failures in a row. |
| `--restart unless-stopped` | Restart after a crash or a host reboot, unless you stopped it yourself. |
| *(no `-p`)* | Nothing is published. The PORTS column of `docker ps` shows plain `3306/tcp`, not `0.0.0.0:3306->...`. |

Wait until all three are healthy (MariaDB takes about 20 s):

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### B.4 Build the images

```bash
docker build -t od-backend:v1  ./backend
docker build -t od-frontend:v1 ./frontend
```

- `./backend` is the **build context** (the files sent to the builder), and `backend/Dockerfile` is the recipe.
- `-t name:version` tags the result.
- The first backend build is slow: it downloads the Maven dependencies. They are cached in their own layer until `pom.xml` changes.

**`backend/Dockerfile`**

| Line | Explanation |
| --- | --- |
| `FROM maven:3.9-eclipse-temurin-21 AS build` | Stage 1: JDK 21 + Maven, only used for building. |
| `COPY pom.xml .` then `RUN mvn -q dependency:go-offline` | Download dependencies **before** copying the source, so code edits don't re-download them. |
| `COPY src ./src` then `RUN mvn -q package -DskipTests` | Compile and package the jar into `target/`. Tests are skipped for the image build. |
| `FROM eclipse-temurin:21-jre` | Stage 2: JRE only, no compiler, no Maven. Much smaller. |
| `RUN useradd --create-home appuser` / `USER appuser` | Run as an unprivileged user. |
| `COPY --from=build /build/target/*.jar app.jar` | Take only the finished jar from stage 1. |
| `EXPOSE 8080` | Documents the port; it publishes nothing. |
| `ENTRYPOINT ["java", "-jar", "app.jar"]` | Start Spring Boot. It listens on `0.0.0.0:8080` (set in `application.properties`), which is required inside a container. |

**`frontend/Dockerfile`**

| Line | Explanation |
| --- | --- |
| `FROM node:24-alpine AS build` | Stage 1: Node, only used for building. |
| `COPY package.json package-lock.json ./` then `RUN npm ci` | Install **exactly** what the lock file says, before copying the source, so the layer stays cached. |
| `COPY . .` | The source. `frontend/.dockerignore` keeps the host's `node_modules`, `dist` and **`.env`** out. |
| `ARG VITE_API_URL=` / `ENV ...` / `RUN npm run build` | Type-check and bundle into `dist/`. Empty means "call `/api/v1` on the same host". |
| `FROM nginx:1.28-alpine` | Stage 2: nginx, no Node. |
| `COPY nginx.conf /etc/nginx/conf.d/default.conf` | Our site config (below). |
| `COPY --from=build /app/dist /usr/share/nginx/html` | Only the built static files. |

**`frontend/nginx.conf`**

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;       # Docker's embedded DNS; re-resolve names every 10 s

server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri /index.html;           # serve the file, else the SPA entry page
    }

    location /api/ {
        set $upstream http://backend:8080;    # a variable forces a DNS lookup at request time
        proxy_pass $upstream;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

Only `/api/` is proxied, so `/actuator/...` is **not** reachable from outside (it falls through to
`index.html`).

### B.5 Start two backend replicas

```bash
for n in 1 2; do
  docker run -d --name backend-$n \
    --network name=web-net,alias=backend \
    --network data-net \
    --env-file backend/.env.docker \
    --restart unless-stopped \
    od-backend:v1
done
```

| Flag | Explanation |
| --- | --- |
| `--network name=web-net,alias=backend` | Join `web-net` with the extra DNS name **`backend`**. Both replicas share the alias, so a lookup returns both IPs. nginx uses that name. |
| `--network data-net` | Also join the internal network to reach `db`, `redis` and `rabbitmq`. (Docker 25+ accepts several `--network` flags.) |
| `--env-file backend/.env.docker` | Datasource, Redis and RabbitMQ settings. |
| *(no `-p`)* | The backend is reachable only through the frontend's nginx. |

Wait for startup, then check health from inside the network:

```bash
docker logs backend-1 --tail 5                 # ... Started OrderDeskApplication
docker run --rm --network web-net curlimages/curl -s backend:8080/actuator/health
```

The second command also proves that name-based DNS works on `web-net`. Expect `"status":"UP"`
with `db`, `redis` and `rabbit` all `UP`.

### B.6 Start the frontend

```bash
docker run -d --name frontend \
  --network web-net \
  -p 8080:80 \
  --restart unless-stopped \
  od-frontend:v1
```

- `-p 8080:80` publishes host port 8080 to nginx's port 80 (`HOST:CONTAINER`). Use `127.0.0.1:8080:80` to accept connections from the host only (see [security](#10-security-notes)).
- `--network web-net` only. The frontend never touches `data-net`.

### B.7 Verify

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -s localhost:8080/ | grep -o '<title>.*</title>'              # <title>Order Desk</title>
curl -s -D - -o /dev/null localhost:8080/api/v1/products           # X-Cache: MISS, then HIT on the second call
for i in 1 2 3 4 5 6; do curl -s -D - -o /dev/null localhost:8080/api/v1/info | grep -i x-instance; done
                                                                    # alternates between the two replicas

curl -s -X POST localhost:8080/api/v1/orders -H 'Content-Type: application/json' \
  -d '{"productId":1,"quantity":1}'                                 # 202, "status":"PENDING"
sleep 4; curl -s localhost:8080/api/v1/orders                       # "status":"CONFIRMED", "processedBy":"<replica id>"
```

Prove the isolation:

```bash
docker port backend-1                                              # prints nothing: no published port
curl -s localhost:8080/actuator/health | head -c 60                 # the React index.html, not JSON
docker exec frontend getent hosts db || echo "db: not resolvable from the frontend (good)"
docker network inspect data-net --format '{{range .Containers}}{{.Name}} {{end}}'
                                                                    # backend-1 backend-2 db redis rabbitmq (no frontend)
```

### B.8 Stop and clean up

```bash
docker rm -f frontend backend-1 backend-2 rabbitmq redis db
docker network rm web-net data-net
# docker volume rm db-data     # ONLY if you want to delete all data
```

---

## C. Docker Compose

Compose reads `docker-compose.yml` and creates everything from section B for you: networks,
containers, replicas, start order and healthchecks.

### C.1 First run

Create `.env.db` and `backend/.env.docker` ([section 3](#3-configuration-files)), then:

```bash
docker compose config -q && echo ok       # validate the file
docker compose up -d --build
docker compose ps
```

| Command | Explanation |
| --- | --- |
| `docker compose up` | Create and start every service, in dependency order. |
| `-d` | Detached: return to the shell. |
| `--build` | Rebuild images that have a `build:` section before starting. Use it after code changes. |
| `docker compose ps` | Lists this project's containers with status and ports. |

Compose names things `<project>-<service>-<n>` and `<project>_<network>`. With `name: orderdesk`
you get `orderdesk-backend-1`, `orderdesk_data-net` and so on. Inside the networks, the
**service name** (`db`, `redis`, `rabbitmq`, `backend`) is the DNS name.

### C.2 `docker-compose.yml` explained

```yaml
name: orderdesk                    # project name, prefix for containers/networks/volumes
```

**Data services**

```yaml
  db:
    image: mariadb:11.8            # = docker run ... mariadb:11.8
    env_file: .env.db              # = --env-file .env.db
    volumes:
      - db-data:/var/lib/mysql     # = -v db-data:/var/lib/mysql
    networks: [data-net]           # internal network only
    healthcheck:                   # = --health-cmd/--health-interval/...
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped
```

`redis` and `rabbitmq` follow the same pattern: only `networks: [data-net]`, no `ports:`, and
their own healthcheck (`redis-cli ping`, `rabbitmq-diagnostics -q ping`).

**`backend`**

```yaml
  backend:
    build: ./backend               # build from backend/Dockerfile ...
    image: od-backend:v1           # ... and tag the result with this name
    env_file: backend/.env.docker  # hosts db / redis / rabbitmq (NOT backend/.env)
    networks: [web-net, data-net]  # reachable by the frontend, can reach the data tier
    deploy:
      replicas: 2                  # two containers; both answer to the DNS name "backend"
    depends_on:
      db:       { condition: service_healthy }   # start only after each healthcheck passes
      redis:    { condition: service_healthy }
      rabbitmq: { condition: service_healthy }
    restart: unless-stopped
```

There is no `ports:` and no `container_name:`. Replicas would clash on both.

**`frontend`**

```yaml
  frontend:
    build: ./frontend
    image: od-frontend:v1
    ports:
      - "8080:80"                  # = -p 8080:80 -- the ONLY published port in the stack
    networks: [web-net]
    depends_on: [backend]
    restart: unless-stopped
```

**Networks and volumes**

```yaml
networks:
  web-net:                         # default bridge network
  data-net:
    internal: true                 # = docker network create --internal

volumes:
  db-data:                         # created and prefixed by Compose: orderdesk_db-data
```

`docker compose down` keeps the volume; `docker compose down -v` deletes it.

### C.3 Everyday Compose commands

| Command | Explanation |
| --- | --- |
| `docker compose ps` | Status of all services. |
| `docker compose logs -f backend` | Follow the logs of every backend replica (Ctrl+C to stop). |
| `docker compose up -d --build backend` | Rebuild and recreate only the backend after a code change. |
| `docker compose up -d --build frontend` | Same for the frontend or after editing `nginx.conf`. |
| `docker compose up -d --scale backend=3` | Run 3 replicas. nginx picks the new one up within 10 s. |
| `docker compose up -d` | Apply edits to `docker-compose.yml` or env files. Only changed services are recreated. |
| `docker compose exec db sh` | Open a shell in the running `db` container. |
| `docker compose stop` | Stop everything, keep the containers. |
| `docker compose down` | Stop and remove containers and networks. The volume is kept. |
| `docker compose config` | Print the final merged config. Useful for spotting typos. |

---

## 7. Accessing the app from your laptop

The stack runs on the EC2 instance. Either open port 8080 in the security group, or (safer)
forward it over SSH:

```bash
ssh -i /path/to/key.pem -N -L 8080:localhost:8080 ubuntu@<EC2_PUBLIC_IP>
```

- `-L 8080:localhost:8080` means "connections to port 8080 on my laptop go through the SSH session to `localhost:8080` on the instance".
- `-N` opens the tunnel without a remote shell. Keep it running while you use the app.

Then open <http://localhost:8080>. Because the API shares the page's origin, **only this one port
is needed** (option A needs 5173, 8080 and 15672).

---

## 8. Day-to-day operations

**Open a SQL shell**

```bash
docker compose exec db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE"'
```

The single quotes make `$MARIADB_*` expand **inside the container**, so the password never appears
on your command line.

**Inspect Redis and RabbitMQ**

```bash
docker compose exec redis redis-cli ttl products:all      # seconds left of the cache entry, -2 = not cached
docker compose exec rabbitmq rabbitmqctl list_queues name messages consumers
                                                          # orders.created and orders.created.dlq
```

`consumers` equals the number of backend replicas on `orders.created`. A growing
`orders.created.dlq` means orders failed processing.

**Back up and restore**

```bash
docker compose exec -T db sh -c 'mariadb-dump -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"' > backup.sql
docker compose exec -T db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" "$MARIADB_DATABASE"' < backup.sql
```

`-T` disables the pseudo-terminal, which is required when you redirect with `>` or `<`.

**Check load balancing and the queue**

```bash
for i in $(seq 10); do curl -s -D - -o /dev/null localhost:8080/api/v1/info | grep -i x-instance; done | sort | uniq -c
for i in 1 2 3 4; do curl -s -o /dev/null -X POST localhost:8080/api/v1/orders \
  -H 'Content-Type: application/json' -d '{"productId":2,"quantity":1}'; done
sleep 8; curl -s localhost:8080/api/v1/orders | grep -o '"processedBy":"[^"]*"' | sort | uniq -c
```

Two different `X-Instance` values show the proxy balancing. Two different `processedBy` values show
RabbitMQ handing messages to whichever replica is free.

**Health check from inside the network**

```bash
docker run --rm --network orderdesk_web-net curlimages/curl -s backend:8080/actuator/health/readiness
```

(Use `--network web-net` for option B.)

---

## 9. Troubleshooting

### `Conflict. The container name "/od-db" is already in use`

The option A throwaway containers (`od-db`, `od-redis`, `od-mq`) or an earlier attempt still exist.
Look first: `docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'`. If they are the
quick-start containers (published ports, default bridge network), remove them by name:
`docker rm -f od-db od-redis od-mq`. Never remove containers you didn't create (a Python stack may
be running on the same host).

### `permission denied while trying to connect to the docker API at unix:///var/run/docker.sock`

Your user isn't in the `docker` group. Use `sudo docker ...`, or `sudo usermod -aG docker "$USER"` and
log in again.

### Frontend shows an error / `502 Bad Gateway` from `/api`

nginx got no answer from `backend:8080`.

- `docker ps`: is a backend container `Up`, or `Restarting`? Read `docker logs backend-1` (or `docker compose logs backend`).
- Is the backend on **`web-net` with the alias `backend`**? In option B the alias is required: `--network name=web-net,alias=backend`.
- nginx logs `backend could not be resolved` when no container has that name: `docker logs frontend`.

### `Connection refused` to `localhost:3306` in the backend logs

The container didn't get its settings, so Spring used the `localhost` defaults from
`application.properties`. Inside a container `localhost` is the container itself. Pass
`--env-file backend/.env.docker` (or `env_file:` in Compose) with hosts `db`, `redis`, `rabbitmq`.

### `Access denied for user 'orderdesk'@...`

MariaDB applies `.env.db` **only when the volume is empty**. If `db-data` was created earlier with
other credentials, changing `.env.db` has no effect. Check from inside:

```bash
docker compose exec db sh -c 'mariadb -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "select current_user()"'
```

If that fails too and you don't need the data: `docker compose down`, `docker volume rm orderdesk_db-data`
(option B: `db-data`), then start again. Make sure `SPRING_DATASOURCE_PASSWORD` equals `MARIADB_PASSWORD`.

### `-p` is ignored / port not reachable

A container attached **only** to an `internal` network gets no published ports, and Docker doesn't
warn you. That is intended for the data services. The frontend is on `web-net`, which is why its
`-p` works.

### The page loads but API calls go to `http://localhost:8080` and fail

`VITE_API_URL` was baked into the JavaScript. That happens when `frontend/.env` is copied into the
build. `frontend/.dockerignore` must contain `.env` (the file is named **`.dockerignore`**, with
the dot). Fix it, then `docker compose up -d --build frontend`. Check with
`docker run --rm od-frontend:v1 grep -rl localhost:8080 /usr/share/nginx/html` (no output = good).

### Orders stay `PENDING`

- Is a listener running? `docker compose exec rabbitmq rabbitmqctl list_queues name messages consumers` should show at least 1 consumer on `orders.created`.
- RabbitMQ was unreachable at the moment the order was saved. Saving and publishing are not atomic (a known simplification, see the README). That order stays `PENDING`.

### `/actuator/health/readiness` is `DOWN`

One of `db`, `redis` or `rabbit` is down. The JSON lists which. Redis down only disables caching
(every response is a `MISS`), but readiness reports it.

### All requests hit one replica

Right after replicas are recreated, nginx may hold the old DNS answer. Wait about 10 s and test again.
Check `docker exec <frontend container> nslookup backend 127.0.0.11`: it should list one IP per replica.

### Files show up in the image that shouldn't (e.g. `.env`, `target/`)

Docker only reads a file named exactly **`.dockerignore`** in the build context.

---

## 10. Security notes

- **Bind the published port to localhost** when you only use the SSH tunnel: `"127.0.0.1:8080:80"`.
  Otherwise anyone the security group lets in can use the API. There is no login.
- **Never commit** `.env.db`, `backend/.env.docker`, `backend/.env` or `frontend/.env`. They are covered by `.gitignore`.
- The data services are only on the internal `data-net`, and the app user can only access its own database.
  RabbitMQ's default `guest/guest` account is acceptable only because the broker is unreachable from outside.
  Use real credentials anywhere else.
- Actuator endpoints are exposed by the backend but not proxied by nginx, so they stay private.
- For anything public: put TLS in front of nginx and add authentication.
