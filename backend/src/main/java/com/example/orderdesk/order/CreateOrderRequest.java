package com.example.orderdesk.order;

import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Positive;

/** Request body for POST /api/v1/orders, e.g. {"productId": 1, "quantity": 2}. */
public record CreateOrderRequest(
        @NotNull @Positive Long productId,
        @NotNull @Min(1) @Max(100) Integer quantity) {
}
