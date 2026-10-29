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

1. Start MariaDB, Redis and RabbitMQ on the ports above (create database/user `orderdesk`).
2. Backend: `cd backend && ./mvnw spring-boot:run` – see [backend/README.md](backend/README.md)
3. Frontend: `cd frontend && cp .env.example .env && npm install && npm run dev` – see [frontend/README.md](frontend/README.md)
4. Open <http://localhost:5173>.

Dockerfiles, docker-compose, nginx config and Terraform are intentionally **not** included –
writing them is the exercise.
