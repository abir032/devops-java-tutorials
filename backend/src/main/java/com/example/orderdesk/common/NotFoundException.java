package com.example.orderdesk.common;

/** Thrown when a requested entity does not exist. Turned into HTTP 404 by {@link GlobalExceptionHandler}. */
public class NotFoundException extends RuntimeException {

    public NotFoundException(String message) {
        super(message);
    }
}
