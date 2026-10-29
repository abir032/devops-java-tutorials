package com.example.orderdesk.product;

import java.util.List;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.domain.Sort;
import org.springframework.stereotype.Service;

import com.example.orderdesk.common.NotFoundException;

@Service
public class ProductService {

    private static final Logger log = LoggerFactory.getLogger(ProductService.class);

    private final ProductRepository repository;
    private final ProductCache cache;

    public ProductService(ProductRepository repository, ProductCache cache) {
        this.repository = repository;
        this.cache = cache;
    }

    /** The product list plus whether it came from the Redis cache. */
    public record ProductList(List<Product> products, boolean cacheHit) {
    }

    /**
     * Cache-aside pattern, done by hand (instead of @Cacheable) so we know
     * whether it was a HIT or a MISS and can report it in the X-Cache header.
     */
    public ProductList findAll() {
        Optional<List<Product>> cached = cache.get();
        if (cached.isPresent()) {
            return new ProductList(cached.get(), true);
        }

        log.info("products loaded from DB");
        List<Product> products = repository.findAll(Sort.by("id"));
        cache.put(products);
        return new ProductList(products, false);
    }

    public Product findById(Long id) {
        return repository.findById(id)
                .orElseThrow(() -> new NotFoundException("Product " + id + " not found"));
    }

    public Product create(ProductRequest request) {
        Product saved = repository.save(new Product(request.name(), request.price(), request.stock()));
        cache.evict();
        return saved;
    }

    public Product update(Long id, ProductRequest request) {
        Product product = findById(id);
        product.setName(request.name());
        product.setPrice(request.price());
        product.setStock(request.stock());
        Product saved = repository.save(product);
        cache.evict();
        return saved;
    }
}
