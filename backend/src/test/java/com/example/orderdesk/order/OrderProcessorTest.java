package com.example.orderdesk.order;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.math.BigDecimal;
import java.util.Optional;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.example.orderdesk.common.InstanceInfo;
import com.example.orderdesk.product.Product;
import com.example.orderdesk.product.ProductRepository;

/** Unit tests for the stock check, with mocked repositories (no database). */
class OrderProcessorTest {

    private OrderRepository orderRepository;
    private ProductRepository productRepository;
    private OrderProcessor processor;

    @BeforeEach
    void setUp() {
        orderRepository = mock(OrderRepository.class);
        productRepository = mock(ProductRepository.class);
        InstanceInfo instanceInfo = mock(InstanceInfo.class);
        when(instanceInfo.getHostname()).thenReturn("test-host");
        processor = new OrderProcessor(orderRepository, productRepository, instanceInfo);
    }

    @Test
    void confirmsOrderAndReducesStockWhenEnoughStock() {
        Product product = product(10);
        Order order = givenOrder(1L, 3, product);

        processor.process(1L);

        assertThat(order.getStatus()).isEqualTo(OrderStatus.CONFIRMED);
        assertThat(order.getProcessedBy()).isEqualTo("test-host");
        assertThat(order.getProcessedAt()).isNotNull();
        assertThat(product.getStock()).isEqualTo(7);
    }

    @Test
    void confirmsOrderThatTakesTheLastItems() {
        Product product = product(3);
        Order order = givenOrder(1L, 3, product);

        processor.process(1L);

        assertThat(order.getStatus()).isEqualTo(OrderStatus.CONFIRMED);
        assertThat(product.getStock()).isZero();
    }

    @Test
    void failsOrderAndKeepsStockWhenNotEnoughStock() {
        Product product = product(2);
        Order order = givenOrder(1L, 3, product);

        processor.process(1L);

        assertThat(order.getStatus()).isEqualTo(OrderStatus.FAILED);
        assertThat(order.getProcessedBy()).isEqualTo("test-host");
        assertThat(product.getStock()).isEqualTo(2);
    }

    @Test
    void skipsOrderThatWasAlreadyProcessed() {
        Product product = product(10);
        Order order = givenOrder(1L, 3, product);
        order.markProcessed(OrderStatus.CONFIRMED, "other-host");

        processor.process(1L);

        assertThat(order.getProcessedBy()).isEqualTo("other-host");
        assertThat(product.getStock()).isEqualTo(10);
        verify(productRepository, never()).findByIdForUpdate(any());
    }

    @Test
    void throwsWhenOrderDoesNotExist() {
        when(orderRepository.findById(99L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> processor.process(99L)).isInstanceOf(IllegalStateException.class);
    }

    private static Product product(int stock) {
        Product product = new Product("Test product", new BigDecimal("9.99"), stock);
        product.setId(5L);
        return product;
    }

    private Order givenOrder(Long orderId, int quantity, Product product) {
        Order order = new Order(product.getId(), quantity);
        when(orderRepository.findById(orderId)).thenReturn(Optional.of(order));
        when(productRepository.findByIdForUpdate(product.getId())).thenReturn(Optional.of(product));
        return order;
    }
}
