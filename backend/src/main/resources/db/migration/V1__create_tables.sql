-- Products that can be ordered.
CREATE TABLE products (
    id    BIGINT         NOT NULL AUTO_INCREMENT,
    name  VARCHAR(100)   NOT NULL,
    price DECIMAL(10, 2) NOT NULL,
    stock INT            NOT NULL,
    PRIMARY KEY (id)
);

-- Orders are created as PENDING by the API and later set to
-- CONFIRMED or FAILED by the RabbitMQ listener.
CREATE TABLE orders (
    id           BIGINT      NOT NULL AUTO_INCREMENT,
    product_id   BIGINT      NOT NULL,
    quantity     INT         NOT NULL,
    status       VARCHAR(20) NOT NULL,
    created_at   DATETIME(6) NOT NULL,
    processed_at DATETIME(6) NULL,
    processed_by VARCHAR(255) NULL,
    PRIMARY KEY (id),
    CONSTRAINT fk_orders_product FOREIGN KEY (product_id) REFERENCES products (id)
);

CREATE INDEX idx_orders_created_at ON orders (created_at);
