package com.example.orderdesk.order;

import java.time.Instant;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

/** An order row from the "orders" table. Also used as the JSON response body. */
@Entity
@Table(name = "orders")
public class Order {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    // Kept as a plain id (no @ManyToOne) to keep the JSON and the code simple.
    @Column(name = "product_id", nullable = false)
    private Long productId;

    @Column(nullable = false)
    private int quantity;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private OrderStatus status;

    @Column(name = "created_at", nullable = false)
    private Instant createdAt;

    @Column(name = "processed_at")
    private Instant processedAt;

    /** Hostname of the backend instance whose listener processed the order. */
    @Column(name = "processed_by")
    private String processedBy;

    /** Required by JPA. */
    protected Order() {
    }

    /** Creates a new PENDING order. */
    public Order(Long productId, int quantity) {
        this.productId = productId;
        this.quantity = quantity;
        this.status = OrderStatus.PENDING;
        this.createdAt = Instant.now();
    }

    /** Marks the order as processed with the given final status. */
    public void markProcessed(OrderStatus finalStatus, String hostname) {
        this.status = finalStatus;
        this.processedAt = Instant.now();
        this.processedBy = hostname;
    }

    public Long getId() {
        return id;
    }

    public Long getProductId() {
        return productId;
    }

    public int getQuantity() {
        return quantity;
    }

    public OrderStatus getStatus() {
        return status;
    }

    public Instant getCreatedAt() {
        return createdAt;
    }

    public Instant getProcessedAt() {
        return processedAt;
    }

    public String getProcessedBy() {
        return processedBy;
    }
}
