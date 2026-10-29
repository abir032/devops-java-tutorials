package com.example.orderdesk.order;

import java.util.List;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
import org.springframework.stereotype.Service;

import com.example.orderdesk.common.NotFoundException;
import com.example.orderdesk.config.RabbitConfig;
import com.example.orderdesk.product.ProductRepository;

@Service
public class OrderService {

    private static final Logger log = LoggerFactory.getLogger(OrderService.class);

    private final OrderRepository orderRepository;
    private final ProductRepository productRepository;
    private final RabbitTemplate rabbitTemplate;

    public OrderService(OrderRepository orderRepository, ProductRepository productRepository,
            RabbitTemplate rabbitTemplate) {
        this.orderRepository = orderRepository;
        this.productRepository = productRepository;
        this.rabbitTemplate = rabbitTemplate;
    }

    /**
     * Saves a PENDING order and publishes an OrderCreated message.
     * The actual work (stock check) happens later in {@link OrderListener}.
     *
     * Deliberately NOT @Transactional: save() commits immediately, so the order is
     * already in the database when a listener (maybe on another instance) receives
     * the message. (If publishing fails the order stays PENDING; production systems
     * solve this with the "transactional outbox" pattern.)
     */
    public Order create(CreateOrderRequest request) {
        if (!productRepository.existsById(request.productId())) {
            throw new NotFoundException("Product " + request.productId() + " not found");
        }

        Order order = orderRepository.save(new Order(request.productId(), request.quantity()));

        rabbitTemplate.convertAndSend(
                RabbitConfig.EXCHANGE,
                RabbitConfig.ROUTING_KEY_ORDER_CREATED,
                new OrderCreatedMessage(order.getId()));
        log.info("Order {} saved as PENDING and published to {}", order.getId(), RabbitConfig.EXCHANGE);

        return order;
    }

    public List<Order> findRecent() {
        return orderRepository.findTop50ByOrderByCreatedAtDescIdDesc();
    }

    public Order findById(Long id) {
        return orderRepository.findById(id)
                .orElseThrow(() -> new NotFoundException("Order " + id + " not found"));
    }
}
