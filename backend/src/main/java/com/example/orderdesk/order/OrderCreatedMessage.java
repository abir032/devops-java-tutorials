package com.example.orderdesk.order;

/**
 * The RabbitMQ message published when an order is created, sent as JSON: {"orderId": 7}.
 * It only carries the id; the listener loads the current data from the database.
 */
public record OrderCreatedMessage(Long orderId) {
}
