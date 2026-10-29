package com.example.orderdesk.common;

/** JSON body returned for every error, e.g. {"error": "Not Found", "message": "Product 42 not found"}. */
public record ErrorResponse(String error, String message) {
}
