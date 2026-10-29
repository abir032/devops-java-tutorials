package com.example.orderdesk.config;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.servlet.config.annotation.CorsRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;

/**
 * Allows the React frontend (served from another origin, e.g. http://localhost:5173)
 * to call the API from the browser.
 *
 * Origins come from APP_CORS_ALLOWED_ORIGINS (comma-separated). When the frontend is
 * served through the same nginx / load balancer host as the API, CORS is not needed at all.
 */
@Configuration
public class CorsConfig implements WebMvcConfigurer {

    private final String[] allowedOrigins;

    public CorsConfig(@Value("${app.cors.allowed-origins}") String[] allowedOrigins) {
        this.allowedOrigins = allowedOrigins;
    }

    @Override
    public void addCorsMappings(CorsRegistry registry) {
        registry.addMapping("/api/**")
                .allowedOrigins(allowedOrigins)
                .allowedMethods("GET", "POST", "PUT", "DELETE", "OPTIONS")
                .allowedHeaders("*")
                // Without this, browser JavaScript cannot read our custom headers.
                .exposedHeaders("X-Cache", "X-Instance");
    }
}
