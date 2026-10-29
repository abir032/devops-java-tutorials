package com.example.orderdesk.config;

import org.springframework.amqp.core.Binding;
import org.springframework.amqp.core.BindingBuilder;
import org.springframework.amqp.core.Queue;
import org.springframework.amqp.core.QueueBuilder;
import org.springframework.amqp.core.TopicExchange;
import org.springframework.amqp.support.converter.JacksonJsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import tools.jackson.databind.json.JsonMapper;

/**
 * RabbitMQ topology. Spring declares these exchanges / queues / bindings on
 * the broker at startup if they don't exist yet.
 *
 * <pre>
 *   POST /api/v1/orders
 *        |  publish (routing key "order.created")
 *        v
 *   [orders.exchange] (topic) ---> [orders.created] ---> OrderListener
 *                                        |
 *                                        | rejected messages
 *                                        v
 *                                 [orders.created.dlq]  (inspect in the management UI :15672)
 * </pre>
 */
@Configuration
public class RabbitConfig {

    public static final String EXCHANGE = "orders.exchange";
    public static final String ROUTING_KEY_ORDER_CREATED = "order.created";
    public static final String QUEUE_ORDER_CREATED = "orders.created";
    public static final String QUEUE_ORDER_CREATED_DLQ = "orders.created.dlq";

    @Bean
    public TopicExchange ordersExchange() {
        return new TopicExchange(EXCHANGE, true, false);
    }

    /**
     * Main work queue. Durable, so messages survive a broker restart.
     * Rejected messages are re-routed through the default exchange ("")
     * straight to the dead-letter queue.
     */
    @Bean
    public Queue orderCreatedQueue() {
        return QueueBuilder.durable(QUEUE_ORDER_CREATED)
                .deadLetterExchange("")
                .deadLetterRoutingKey(QUEUE_ORDER_CREATED_DLQ)
                .build();
    }

    /** Dead-letter queue: messages that could not be processed end up here. */
    @Bean
    public Queue orderCreatedDeadLetterQueue() {
        return QueueBuilder.durable(QUEUE_ORDER_CREATED_DLQ).build();
    }

    @Bean
    public Binding orderCreatedBinding(Queue orderCreatedQueue, TopicExchange ordersExchange) {
        return BindingBuilder.bind(orderCreatedQueue).to(ordersExchange).with(ROUTING_KEY_ORDER_CREATED);
    }

    /**
     * Send and receive messages as JSON instead of Java serialization.
     * Spring Boot plugs this bean into both RabbitTemplate and @RabbitListener.
     */
    @Bean
    public MessageConverter jsonMessageConverter(JsonMapper jsonMapper) {
        return new JacksonJsonMessageConverter(jsonMapper);
    }
}
