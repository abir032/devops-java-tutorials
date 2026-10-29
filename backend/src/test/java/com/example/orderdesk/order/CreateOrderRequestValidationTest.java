package com.example.orderdesk.order;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.Set;
import java.util.stream.Collectors;

import jakarta.validation.ConstraintViolation;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import jakarta.validation.ValidatorFactory;

import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

/**
 * Checks the Bean Validation rules on {@link CreateOrderRequest}
 * using a plain Validator - no Spring context, database or broker needed.
 */
class CreateOrderRequestValidationTest {

    private static ValidatorFactory factory;
    private static Validator validator;

    @BeforeAll
    static void setUp() {
        factory = Validation.buildDefaultValidatorFactory();
        validator = factory.getValidator();
    }

    @AfterAll
    static void tearDown() {
        factory.close();
    }

    @Test
    void validRequestHasNoViolations() {
        assertThat(invalidFields(new CreateOrderRequest(1L, 2))).isEmpty();
    }

    @Test
    void productIdIsRequired() {
        assertThat(invalidFields(new CreateOrderRequest(null, 2))).containsExactly("productId");
    }

    @Test
    void productIdMustBePositive() {
        assertThat(invalidFields(new CreateOrderRequest(0L, 2))).containsExactly("productId");
    }

    @Test
    void quantityIsRequired() {
        assertThat(invalidFields(new CreateOrderRequest(1L, null))).containsExactly("quantity");
    }

    @Test
    void quantityMustBeAtLeastOne() {
        assertThat(invalidFields(new CreateOrderRequest(1L, 0))).containsExactly("quantity");
        assertThat(invalidFields(new CreateOrderRequest(1L, -5))).containsExactly("quantity");
    }

    @Test
    void quantityMustNotExceedOneHundred() {
        assertThat(invalidFields(new CreateOrderRequest(1L, 100))).isEmpty();
        assertThat(invalidFields(new CreateOrderRequest(1L, 101))).containsExactly("quantity");
    }

    private static Set<String> invalidFields(CreateOrderRequest request) {
        Set<ConstraintViolation<CreateOrderRequest>> violations = validator.validate(request);
        return violations.stream()
                .map(v -> v.getPropertyPath().toString())
                .collect(Collectors.toSet());
    }
}
