package com.example.orderdesk.order;

/**
 * Lifecycle of an order:
 * PENDING (saved by the API) -> CONFIRMED or FAILED (decided by the RabbitMQ listener).
 */
public enum OrderStatus {
    PENDING,
    CONFIRMED,
    FAILED
}
