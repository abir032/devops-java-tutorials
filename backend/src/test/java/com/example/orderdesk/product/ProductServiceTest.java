package com.example.orderdesk.product;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.Sort;

import com.example.orderdesk.common.NotFoundException;

/** Unit tests for the cache-aside logic, with a mocked cache and repository. */
class ProductServiceTest {

    private ProductRepository repository;
    private ProductCache cache;
    private ProductService service;

    @BeforeEach
    void setUp() {
        repository = mock(ProductRepository.class);
        cache = mock(ProductCache.class);
        service = new ProductService(repository, cache);
    }

    @Test
    void cacheHitDoesNotTouchTheDatabase() {
        List<Product> cached = List.of(new Product("Cached", BigDecimal.ONE, 1));
        when(cache.get()).thenReturn(Optional.of(cached));

        ProductService.ProductList result = service.findAll();

        assertThat(result.cacheHit()).isTrue();
        assertThat(result.products()).isEqualTo(cached);
        verify(repository, never()).findAll(any(Sort.class));
    }

    @Test
    void cacheMissLoadsFromDatabaseAndFillsTheCache() {
        List<Product> fromDb = List.of(new Product("From DB", BigDecimal.TEN, 5));
        when(cache.get()).thenReturn(Optional.empty());
        when(repository.findAll(any(Sort.class))).thenReturn(fromDb);

        ProductService.ProductList result = service.findAll();

        assertThat(result.cacheHit()).isFalse();
        assertThat(result.products()).isEqualTo(fromDb);
        verify(cache).put(fromDb);
    }

    @Test
    void creatingAProductEvictsTheCache() {
        when(repository.save(any(Product.class))).thenAnswer(invocation -> invocation.getArgument(0));

        Product created = service.create(new ProductRequest("New", new BigDecimal("1.50"), 3));

        assertThat(created.getName()).isEqualTo("New");
        verify(cache).evict();
    }

    @Test
    void updatingAMissingProductThrowsNotFound() {
        when(repository.findById(42L)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.update(42L, new ProductRequest("X", BigDecimal.ONE, 1)))
                .isInstanceOf(NotFoundException.class)
                .hasMessage("Product 42 not found");
        verify(cache, never()).evict();
    }
}
