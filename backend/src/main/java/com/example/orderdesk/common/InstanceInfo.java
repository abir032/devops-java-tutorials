package com.example.orderdesk.common;

import java.net.InetAddress;
import java.net.UnknownHostException;

import org.springframework.stereotype.Component;

/**
 * Knows the name of the machine / container this backend runs on.
 *
 * Inside Docker the hostname is the container id, on EC2 it is the instance's
 * private DNS name. Showing it in responses makes load balancing visible.
 */
@Component
public class InstanceInfo {

    private final String hostname = resolveHostname();

    public String getHostname() {
        return hostname;
    }

    private static String resolveHostname() {
        try {
            return InetAddress.getLocalHost().getHostName();
        } catch (UnknownHostException e) {
            // Fall back to the HOSTNAME env var (set by Docker and most shells).
            String env = System.getenv("HOSTNAME");
            return env != null ? env : "unknown";
        }
    }
}
