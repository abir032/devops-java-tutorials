# Order Desk

A small full-stack demo app for learning **Docker** and **AWS deployment**.
You place orders for products. The orders are processed asynchronously via a message queue,
and the product list is cached in Redis.

```
monorepo
├── backend/    Spring Boot 4, Java 21, Maven  (REST API + RabbitMQ listener)
└── frontend/   React + TypeScript + Vite      (static single page app)
```

## Architecture

### Overview

```
                      (nginx, added later)
  Browser ──HTTP──▶   /       → frontend/dist (static files)
                      /api/*  → backend :8080 (Spring Boot, 1..n instances)
                                   │
                                   ├── JDBC ──▶ MariaDB  :3306   tables products, orders
                                   ├── RESP ──▶ Redis    :6379   cache key "products:all" (60 s)
                                   └── AMQP ──▶ RabbitMQ :5672   orders.exchange → orders.created
                                                         :15672  management UI
```

1. The browser loads the React app (static files from `frontend/dist`).
2. The app calls `/api/v1/...`. Later, nginx serves the static files and proxies `/api` to the
   backend, so both come from the same origin. In local dev the app calls `http://localhost:8080` directly (CORS).
3. **Products**: `GET /api/v1/products` checks Redis first (`X-Cache: HIT`), otherwise reads
   MariaDB and caches the result (`X-Cache: MISS`). Creating or updating a product clears the cache.
4. **Orders**: `POST /api/v1/orders` saves the order as `PENDING` and publishes a message to
   RabbitMQ, then returns `202 Accepted`. A listener (in *every* backend instance) picks the
   message up, waits 3 s, reduces stock and marks the order `CONFIRMED` or `FAILED`.
   Failed messages land in the dead-letter queue `orders.created.dlq`.
5. Every response has an `X-Instance` header with the backend's hostname, and orders record
   `processedBy`. Run several backend instances behind a load balancer to see them share the work.

The backend is **stateless**: all state lives in MariaDB, Redis and RabbitMQ, so you can run as
many backend containers as you like.

### Components

| Component | Technology | Responsibility | State |
|-----------|------------|----------------|-------|
| Frontend  | React 19 + TypeScript, built by Vite | UI; calls the REST API, polls orders every 2 s | none (static files) |
| Backend   | Spring Boot 4, Java 21 | REST API, cache-aside logic, publishes and consumes order messages | none (stateless) |
| MariaDB   | MariaDB 11 | Source of truth: products and orders. Schema managed by Flyway | persistent |
| Redis     | Redis 7 | Cache of the product list (`products:all`, TTL 60 s) | disposable |
| RabbitMQ  | RabbitMQ 4 | Queues order work between the API and the listeners | durable queues |

Redis holds only a cache. If Redis is down, the backend logs a warning and reads from MariaDB
(every request is a `MISS`), but `/actuator/health/readiness` reports DOWN.

### Data model

```
products                              orders
────────────────────────              ─────────────────────────────────
id     BIGINT  PK auto                id            BIGINT  PK auto
name   VARCHAR(100)                   product_id    BIGINT  FK → products.id
price  DECIMAL(10,2)                  quantity      INT
stock  INT                            status        PENDING | CONFIRMED | FAILED
                                      created_at    DATETIME(6)
                                      processed_at  DATETIME(6)  NULL until processed
                                      processed_by  VARCHAR(255) hostname of the listener
```

Migrations live in `backend/src/main/resources/db/migration`:
`V1__create_tables.sql` creates the tables and `V2__seed_products.sql` adds 5 sample products.
Flyway runs them on startup. Hibernate only *validates* the schema (`ddl-auto=validate`).

### RabbitMQ topology

```
 OrderService                                                        OrderListener
 (POST /orders) ──publish──▶ [orders.exchange]  ──"order.created"──▶ [orders.created] ──▶ (every instance)
                             topic, durable                           durable queue
                                                                          │ reject, no requeue
                                                                          ▼
                                                                    [orders.created.dlq]
```

- The message is JSON with only the id, e.g. `{"orderId": 7}`. The listener reads the current
  data from MariaDB.
- `orders.created` has `x-dead-letter-exchange=""` and `x-dead-letter-routing-key=orders.created.dlq`,
  so a rejected message goes straight to the DLQ. If processing throws, the listener throws
  `AmqpRejectAndDontRequeueException`, so a bad message is never retried forever.
- The backend declares all exchanges, queues and bindings on startup. Nothing needs to be
  created by hand.

### Request flows

**List products (cache-aside)**

```
Browser → GET /api/v1/products → ProductService
            ├─ Redis GET products:all ── found ──▶ 200, X-Cache: HIT
            └─ not found ─▶ MariaDB SELECT * FROM products
                            ─▶ Redis SET products:all EX 60 ─▶ 200, X-Cache: MISS
                               (log "products loaded from DB")
```

**Place an order (asynchronous)**

```
Browser            Backend (API)            MariaDB      RabbitMQ       Backend (any listener)
   │ POST /orders      │                       │             │                    │
   │──────────────────▶│ validate body (400)   │             │                    │
   │                   │ product exists? (404) │             │                    │
   │                   │── INSERT PENDING ────▶│             │                    │
   │                   │── publish {orderId} ───────────────▶│                    │
   │◀── 202 PENDING ───│                       │             │── deliver ────────▶│
   │                   │                       │             │                    │ sleep 3 s
   │                   │                       │◀── SELECT … FOR UPDATE (product) ─│
   │                   │                       │◀── UPDATE stock, status ──────────│ CONFIRMED / FAILED
   │                   │                       │             │◀──── ack ──────────│ + DEL products:all
   │ GET /orders (polling every 2 s) shows the new status                         │
```

### Backend code layout

```
backend/src/main/java/com/example/orderdesk/
├── OrderDeskApplication.java   entry point
├── config/
│   ├── CorsConfig.java         CORS for /api/** from APP_CORS_ALLOWED_ORIGINS, exposes X-Cache / X-Instance
│   └── RabbitConfig.java       exchange, queues, DLQ, binding, JSON message converter
├── common/
│   ├── InstanceInfo.java       resolves this machine's hostname
│   ├── InstanceHeaderFilter.java  adds X-Instance to every response
│   ├── GlobalExceptionHandler.java  JSON {error, message}: 400 / 404 / 500
│   ├── ErrorResponse.java, NotFoundException.java
├── product/
│   ├── ProductController.java  /api/v1/products
│   ├── ProductService.java     cache-aside logic, evicts on create / update
│   ├── ProductCache.java       Redis access (StringRedisTemplate + JSON)
│   └── Product.java, ProductRepository.java, ProductRequest.java
├── order/
│   ├── OrderController.java    /api/v1/orders
│   ├── OrderService.java       save PENDING + publish message
│   ├── OrderListener.java      @RabbitListener: delay, process, DLQ on error, evict cache
│   ├── OrderProcessor.java     @Transactional stock check → CONFIRMED / FAILED
│   └── Order.java, OrderStatus.java, OrderRepository.java, CreateOrderRequest.java, OrderCreatedMessage.java
└── info/
    └── InfoController.java     /api/v1/info
```

Frontend: `src/api.ts` (all HTTP calls and headers), `App.tsx` (layout + footer),
`ProductsTable.tsx`, `OrderForm.tsx`, `OrdersTable.tsx`, `styles.css`.

### Scaling and consistency

These design choices are what let you run several backend instances safely:

- **Stateless backend**: no sessions or local files. Any instance can answer any request.
- **Competing consumers**: all instances listen on the same queue, and RabbitMQ delivers each
  message to exactly one of them. `processedBy` shows which one.
- **Row lock on stock**: `OrderProcessor` loads the product with `SELECT … FOR UPDATE`, so two
  instances cannot both sell the last item.
- **Idempotent processing**: an order that is no longer `PENDING` is skipped, so a duplicate
  delivery (e.g. after a crash) does no harm.
- **Shared cache**: Redis is shared by all instances, so evicting `products:all` on one instance
  affects all of them.
- **Graceful shutdown**: on SIGTERM, in-flight HTTP requests finish (up to 20 s) before the
  process exits, which makes rolling deploys clean.
- **Known simplification**: saving the order and publishing the message are not atomic. If
  RabbitMQ is unreachable at that moment, the order stays `PENDING`. Production systems use the
  *transactional outbox* pattern for this.

### Target deployment on AWS (for the exercise)

| Local piece | Typical AWS service |
|-------------|---------------------|
| nginx / load balancer | Application Load Balancer (health check `/actuator/health/readiness`) |
| frontend `dist/` | nginx container, or S3 + CloudFront |
| backend containers | ECS (Fargate or EC2) or plain EC2 with Docker, 2+ tasks |
| MariaDB | Amazon RDS for MariaDB |
| Redis | Amazon ElastiCache (Redis / Valkey) |
| RabbitMQ | Amazon MQ for RabbitMQ (TLS on port 5671: also set `SPRING_RABBITMQ_SSL_ENABLED=true`) |
| `.env` values | ECS task env vars, with passwords from Secrets Manager / SSM Parameter Store |

## Ports

| Port  | Service                          |
|-------|----------------------------------|
| 8080  | backend (API + `/actuator`)      |
| 3306  | MariaDB                          |
| 6379  | Redis                            |
| 5672  | RabbitMQ (AMQP)                  |
| 15672 | RabbitMQ management UI           |
| 5173  | frontend dev server (`npm run dev`, local dev only) |

## Environment variables

### Backend (runtime) – see [backend/.env.example](backend/.env.example)

| Variable                     | Local default                             |
|------------------------------|-------------------------------------------|
| `SPRING_DATASOURCE_URL`      | `jdbc:mariadb://localhost:3306/orderdesk` |
| `SPRING_DATASOURCE_USERNAME` | `orderdesk`                               |
| `SPRING_DATASOURCE_PASSWORD` | `orderdesk`                               |
| `SPRING_DATA_REDIS_HOST`     | `localhost`                               |
| `SPRING_DATA_REDIS_PORT`     | `6379`                                    |
| `SPRING_RABBITMQ_HOST`       | `localhost`                               |
| `SPRING_RABBITMQ_PORT`       | `5672`                                    |
| `SPRING_RABBITMQ_USERNAME`   | `guest`                                   |
| `SPRING_RABBITMQ_PASSWORD`   | `guest`                                   |
| `APP_CORS_ALLOWED_ORIGINS`   | `http://localhost:5173` (comma-separated) |

### Frontend (build time) – see [frontend/.env.example](frontend/.env.example)

| Variable       | Meaning |
|----------------|---------|
| `VITE_API_URL` | Backend base URL, e.g. `http://localhost:8080`. Leave unset to call `/api` on the same host (behind nginx). Baked in by `npm run build`. |

Copy `.env.example` to `.env` to use it. `.env` files are git-ignored – never commit real secrets.

## Health checks

| Endpoint                         | Use for |
|----------------------------------|---------|
| `/actuator/health`               | overall status incl. `db`, `redis`, `rabbit` |
| `/actuator/health/liveness`      | "is the process alive?" → restart if DOWN |
| `/actuator/health/readiness`     | "can it take traffic?" → load balancer target health |
| `/api/v1/info`                   | `{ "instance": "<hostname>", "version": "..." }` |

The backend shuts down gracefully (finishes in-flight requests) when it receives SIGTERM.

## Run locally

1. Start MariaDB, Redis and RabbitMQ on the ports above (database/user `orderdesk`).
   The quickest way is three throwaway containers:

   ```bash
   docker run -d --rm --name od-db -p 3306:3306 \
     -e MARIADB_DATABASE=orderdesk -e MARIADB_USER=orderdesk \
     -e MARIADB_PASSWORD=orderdesk -e MARIADB_ROOT_PASSWORD=root mariadb:11
   docker run -d --rm --name od-redis -p 6379:6379 redis:7
   docker run -d --rm --name od-mq -p 5672:5672 -p 15672:15672 rabbitmq:4-management
   ```

2. Backend: `cd backend && ./mvnw spring-boot:run` – see [backend/README.md](backend/README.md)
3. Frontend: `cd frontend && cp .env.example .env && npm install && npm run dev` – see [frontend/README.md](frontend/README.md)
4. Open <http://localhost:5173>.

Stop everything: `Ctrl+C` the backend and frontend, then `docker stop od-db od-redis od-mq`
(`--rm` deletes the containers and their data).

### Running on a remote server (e.g. EC2)

When the app runs on a remote machine, forward the ports over SSH and use the same
`localhost` URLs in your own browser:

```bash
ssh -i /path/to/key.pem -N \
  -L 5173:localhost:5173 -L 8080:localhost:8080 -L 15672:localhost:15672 \
  ubuntu@<server-public-ip>
```

## Docker

Dockerfiles, `docker-compose.yml` and the nginx config are included. The **[Setup Guide](doc/SETUP.md)**
covers the architecture (public frontend, private data network), running every container by hand,
and Docker Compose with two backend replicas.

```bash
cp .env.db.example .env.db && cp backend/.env.docker.example backend/.env.docker   # then fill in the passwords
docker compose up -d --build
```

Open <http://localhost:8080>. Terraform for AWS is intentionally **not** included – writing it is the exercise.
