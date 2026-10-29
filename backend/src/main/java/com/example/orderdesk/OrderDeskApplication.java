package com.example.orderdesk;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Entry point of the Order Desk backend.
 *
 * Everything else (web server, database, Redis, RabbitMQ, Flyway, Actuator)
 * is wired up by Spring Boot auto-configuration based on application.properties.
 */
@SpringBootApplication
public class OrderDeskApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrderDeskApplication.class, args);
    }
}
