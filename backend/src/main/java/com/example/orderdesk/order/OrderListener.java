package com.example.orderdesk.order;

import java.time.Duration;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.amqp.AmqpRejectAndDontRequeueException;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import com.example.orderdesk.config.RabbitConfig;
import com.example.orderdesk.product.ProductCache;

/**
 * Consumes OrderCreated messages from the "orders.created" queue.
 *
 * Every running backend instance listens on the same queue, and RabbitMQ hands
 * each message to exactly one of them - check the processed_by column to see who.
 */
@Component
public class OrderListener {

    private static final Logger log = LoggerFactory.getLogger(OrderListener.class);

    private final OrderProcessor processor;
    private final ProductCache productCache;
    private final Duration processingDelay;

    public OrderListener(OrderProcessor processor, ProductCache productCache,
            @Value("${app.orders.processing-delay:3s}") Duration processingDelay) {
        this.processor = processor;
        this.productCache = productCache;
        this.processingDelay = processingDelay;
    }

    @RabbitListener(queues = RabbitConfig.QUEUE_ORDER_CREATED)
    public void onOrderCreated(OrderCreatedMessage message) {
        log.info("Received OrderCreated for order {}", message.orderId());
        try {
            simulateWork();
            processor.process(message.orderId());
        } catch (Exception e) {
            // Reject without requeue -> RabbitMQ routes the message to orders.created.dlq.
            log.error("Processing order {} failed, sending message to the DLQ", message.orderId(), e);
            throw new AmqpRejectAndDontRequeueException("Processing order " + message.orderId() + " failed", e);
        }

        // Stock changed, so the cached product list is stale.
        productCache.evict();
    }

    /** Pretend this is slow work (calling a payment provider, etc.). */
    private void simulateWork() throws InterruptedException {
        Thread.sleep(processingDelay.toMillis());
    }
}
