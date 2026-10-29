package com.example.orderdesk.product;

import java.time.Duration;
import java.util.List;
import java.util.Optional;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

/**
 * Stores the full product list in Redis as a JSON string under the key "products:all".
 *
 * The cache is only an optimisation: if Redis is down we log a warning and
 * fall back to the database instead of failing the request.
 * Try it: `redis-cli GET products:all` and `redis-cli TTL products:all`.
 */
@Component
public class ProductCache {

    public static final String KEY = "products:all";
    public static final Duration TTL = Duration.ofSeconds(60);

    private static final Logger log = LoggerFactory.getLogger(ProductCache.class);
    private static final TypeReference<List<Product>> PRODUCT_LIST = new TypeReference<>() { };

    private final StringRedisTemplate redis;
    private final JsonMapper jsonMapper;

    public ProductCache(StringRedisTemplate redis, JsonMapper jsonMapper) {
        this.redis = redis;
        this.jsonMapper = jsonMapper;
    }

    /** Returns the cached list, or empty if there is nothing cached (or Redis is unavailable). */
    public Optional<List<Product>> get() {
        try {
            String json = redis.opsForValue().get(KEY);
            return json == null ? Optional.empty() : Optional.of(jsonMapper.readValue(json, PRODUCT_LIST));
        } catch (RuntimeException e) {
            log.warn("Could not read {} from Redis: {}", KEY, e.getMessage());
            return Optional.empty();
        }
    }

    /** Caches the list for {@link #TTL}; Redis deletes the key automatically afterwards. */
    public void put(List<Product> products) {
        try {
            redis.opsForValue().set(KEY, jsonMapper.writeValueAsString(products), TTL);
        } catch (RuntimeException e) {
            log.warn("Could not write {} to Redis: {}", KEY, e.getMessage());
        }
    }

    /** Removes the cached list, so the next GET reloads it from the database. */
    public void evict() {
        try {
            redis.delete(KEY);
        } catch (RuntimeException e) {
            log.warn("Could not delete {} from Redis: {}", KEY, e.getMessage());
        }
    }
}
