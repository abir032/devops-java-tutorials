package com.example.orderdesk.common;

import java.io.IOException;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Adds "X-Instance: <hostname>" to every HTTP response,
 * so you can see which backend instance answered a request.
 */
@Component
public class InstanceHeaderFilter extends OncePerRequestFilter {

    public static final String HEADER = "X-Instance";

    private final InstanceInfo instanceInfo;

    public InstanceHeaderFilter(InstanceInfo instanceInfo) {
        this.instanceInfo = instanceInfo;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
            throws ServletException, IOException {
        // Set the header before the request is handled, so it is present
        // even if the controller writes the response or throws an error.
        response.setHeader(HEADER, instanceInfo.getHostname());
        chain.doFilter(request, response);
    }
}
