package com.example.orderdesk.info;

import java.util.Map;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import com.example.orderdesk.common.InstanceInfo;

/** GET /api/v1/info -> which instance answered and which version is deployed. */
@RestController
public class InfoController {

    private final InstanceInfo instanceInfo;
    private final String version;

    public InfoController(InstanceInfo instanceInfo, @Value("${info.app.version:unknown}") String version) {
        this.instanceInfo = instanceInfo;
        this.version = version;
    }

    @GetMapping("/api/v1/info")
    public Map<String, String> info() {
        return Map.of(
                "instance", instanceInfo.getHostname(),
                "version", version);
    }
}
