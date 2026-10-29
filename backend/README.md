# Order Desk – backend

Spring Boot 4 (Java 21) REST API backed by **MariaDB** (data), **Redis** (product list cache)
and **RabbitMQ** (asynchronous order processing).

## Prerequisites

- Java 21 (`java -version`)
- Running MariaDB, Redis and RabbitMQ. By default the app expects them on `localhost`:

| Service  | Port  | Default credentials                    |
|----------|-------|----------------------------------------|
| MariaDB  | 3306  | database `orderdesk`, user/password `orderdesk` |
| Redis    | 6379  | none                                   |
| RabbitMQ | 5672  | `guest` / `guest` (management UI on 15672) |

Maven itself is not needed: `./mvnw` downloads the right version on first use.

The database schema and 5 sample products are created by Flyway on startup
(`src/main/resources/db/migration`). You only need an empty database and a user:

```sql
CREATE DATABASE orderdesk;
CREATE USER 'orderdesk'@'%' IDENTIFIED BY 'orderdesk';
GRANT ALL PRIVILEGES ON orderdesk.* TO 'orderdesk'@'%';
```

The RabbitMQ exchange and queues are declared automatically on startup too.

## Run

```bash
./mvnw spring-boot:run
```

The API listens on <http://localhost:8080>.

To point the app at other servers, set environment variables (see [.env.example](.env.example)):

```bash
SPRING_DATASOURCE_URL=jdbc:mariadb://db.example.internal:3306/orderdesk \
SPRING_DATASOURCE_PASSWORD=secret \
SPRING_DATA_REDIS_HOST=redis.example.internal \
./mvnw spring-boot:run
```

Or load a `.env` file into your shell first (`.env` is git-ignored):

```bash
cp .env.example .env      # then edit .env
set -a; source .env; set +a
./mvnw spring-boot:run
```

### Environment variables

| Variable                     | Default                                    |
|------------------------------|--------------------------------------------|
| `SPRING_DATASOURCE_URL`      | `jdbc:mariadb://localhost:3306/orderdesk`  |
| `SPRING_DATASOURCE_USERNAME` | `orderdesk`                                |
| `SPRING_DATASOURCE_PASSWORD` | `orderdesk`                                |
| `SPRING_DATA_REDIS_HOST`     | `localhost`                                |
| `SPRING_DATA_REDIS_PORT`     | `6379`                                     |
| `SPRING_RABBITMQ_HOST`       | `localhost`                                |
| `SPRING_RABBITMQ_PORT`       | `5672`                                     |
| `SPRING_RABBITMQ_USERNAME`   | `guest`                                    |
| `SPRING_RABBITMQ_PASSWORD`   | `guest`                                    |
| `APP_CORS_ALLOWED_ORIGINS`   | `http://localhost:5173` (comma-separated)  |

## Test and build

```bash
./mvnw test       # unit tests, no database / Docker needed
./mvnw package    # builds target/order-desk-0.0.1-SNAPSHOT.jar
java -jar target/order-desk-0.0.1-SNAPSHOT.jar
```

## API

| Method | Path                     | Notes |
|--------|--------------------------|-------|
| GET    | `/api/v1/products`       | Cached in Redis (`products:all`, 60 s). Header `X-Cache: HIT` / `MISS` |
| GET    | `/api/v1/products/{id}`  | |
| POST   | `/api/v1/products`       | `{"name","price","stock"}`, evicts the cache |
| PUT    | `/api/v1/products/{id}`  | same body, evicts the cache |
| POST   | `/api/v1/orders`         | `{"productId": 1, "quantity": 2}` → `202 Accepted`, status `PENDING` |
| GET    | `/api/v1/orders`         | 50 newest orders |
| GET    | `/api/v1/orders/{id}`    | |
| GET    | `/api/v1/info`           | `{"instance": "<hostname>", "version": "0.0.1-SNAPSHOT"}` |
| GET    | `/actuator/health`       | includes `db`, `redis`, `rabbit` |
| GET    | `/actuator/health/liveness`, `/actuator/health/readiness` | for container / load balancer health checks |
| GET    | `/actuator/info`         | |

Every response has an `X-Instance: <hostname>` header. Errors are JSON:
`{"error": "Bad Request", "message": "quantity: must be greater than or equal to 1"}`.

### Try it

```bash
curl -i localhost:8080/api/v1/products          # X-Cache: MISS
curl -i localhost:8080/api/v1/products          # X-Cache: HIT
curl -i -X POST localhost:8080/api/v1/orders \
     -H 'Content-Type: application/json' -d '{"productId":1,"quantity":2}'
sleep 4; curl localhost:8080/api/v1/orders      # status CONFIRMED, processed_by = your hostname
```

## How order processing works

1. `POST /api/v1/orders` saves the order as `PENDING` and publishes `{"orderId": 7}` to the
   topic exchange `orders.exchange` with routing key `order.created`.
2. The durable queue `orders.created` is bound to that key. `OrderListener` consumes it,
   waits 3 seconds (simulated work), then in one transaction reduces stock → `CONFIRMED`,
   or leaves stock alone → `FAILED`. It records `processed_at` and `processed_by` (hostname)
   and evicts the `products:all` cache.
3. If processing throws, the message is rejected without requeue and RabbitMQ moves it to
   `orders.created.dlq`. Inspect it in the management UI at <http://localhost:15672>.

When several backend instances run, they all consume from the same queue and RabbitMQ gives
each message to exactly one of them – watch the `processed_by` column.
