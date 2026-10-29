package com.example.orderdesk.order;

import java.util.List;

import org.springframework.data.jpa.repository.JpaRepository;

public interface OrderRepository extends JpaRepository<Order, Long> {

    /** The 50 newest orders. Spring Data builds the SQL from the method name. */
    List<Order> findTop50ByOrderByCreatedAtDescIdDesc();
}
