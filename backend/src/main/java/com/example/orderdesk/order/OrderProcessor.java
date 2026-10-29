package com.example.orderdesk.order;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import com.example.orderdesk.common.InstanceInfo;
import com.example.orderdesk.product.Product;
import com.example.orderdesk.product.ProductRepository;

/**
 * The business logic of processing an order: reserve stock or fail.
 * Runs in one database transaction, so stock and order status change together.
 */
@Service
public class OrderProcessor {

    private static final Logger log = LoggerFactory.getLogger(OrderProcessor.class);

    private final OrderRepository orderRepository;
    private final ProductRepository productRepository;
    private final InstanceInfo instanceInfo;

    public OrderProcessor(OrderRepository orderRepository, ProductRepository productRepository,
            InstanceInfo instanceInfo) {
        this.orderRepository = orderRepository;
        this.productRepository = productRepository;
        this.instanceInfo = instanceInfo;
    }

    @Transactional
    public Order process(Long orderId) {
        Order order = orderRepository.findById(orderId)
                .orElseThrow(() -> new IllegalStateException("Order " + orderId + " does not exist"));

        // A message can be delivered more than once (e.g. after a crash). Only process each order once.
        if (order.getStatus() != OrderStatus.PENDING) {
            log.info("Order {} already {}, skipping", orderId, order.getStatus());
            return order;
        }

        Product product = productRepository.findByIdForUpdate(order.getProductId())
                .orElseThrow(() -> new IllegalStateException("Product " + order.getProductId() + " does not exist"));

        if (product.getStock() >= order.getQuantity()) {
            product.setStock(product.getStock() - order.getQuantity());
            order.markProcessed(OrderStatus.CONFIRMED, instanceInfo.getHostname());
        } else {
            order.markProcessed(OrderStatus.FAILED, instanceInfo.getHostname());
        }

        // No explicit save() needed: JPA writes changes to managed entities on commit.
        log.info("Order {} {} (product {}, quantity {}, stock left {})",
                orderId, order.getStatus(), product.getId(), order.getQuantity(), product.getStock());
        return order;
    }
}
