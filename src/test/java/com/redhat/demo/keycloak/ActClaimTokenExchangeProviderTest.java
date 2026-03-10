package com.redhat.demo.keycloak;

import java.util.HashMap;
import java.util.Map;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ActClaimTokenExchangeProviderTest {

    @Test
    void testFactoryId() {
        ActClaimTokenExchangeProviderFactory factory = new ActClaimTokenExchangeProviderFactory();
        assertEquals("act-claim-exchange", factory.getId());
    }

    @Test
    void testActClaimFirstHop() {
        Map<String, Object> result = ActClaimTokenExchangeProvider.buildActClaim("orchestrator", null);

        assertNotNull(result);
        assertEquals("orchestrator", result.get("sub"));
        assertNull(result.get("act"));
    }

    @Test
    void testActClaimChaining() {
        Map<String, Object> existingAct = new HashMap<>();
        existingAct.put("sub", "orchestrator");

        Map<String, Object> result = ActClaimTokenExchangeProvider.buildActClaim("summarizer", existingAct);

        assertNotNull(result);
        assertEquals("summarizer", result.get("sub"));

        @SuppressWarnings("unchecked")
        Map<String, Object> nestedAct = (Map<String, Object>) result.get("act");
        assertNotNull(nestedAct);
        assertEquals("orchestrator", nestedAct.get("sub"));
    }

    @Test
    void testNoActorToken() {
        Map<String, Object> result = ActClaimTokenExchangeProvider.buildActClaim(null, null);
        assertNull(result);
    }

    @Test
    void testActClaimSubIsActorSub() {
        String actorSub = "agent-alpha";
        Map<String, Object> result = ActClaimTokenExchangeProvider.buildActClaim(actorSub, null);

        assertNotNull(result);
        assertEquals(actorSub, result.get("sub"));
    }

    @Test
    void testActClaimDepthCap() {
        // Build a chain of depth 10
        Map<String, Object> deepAct = new HashMap<>();
        deepAct.put("sub", "agent-0");
        Map<String, Object> current = deepAct;
        for (int i = 1; i < 10; i++) {
            Map<String, Object> nested = new HashMap<>();
            nested.put("sub", "agent-" + i);
            nested.put("act", current);
            current = nested;
        }

        // At depth 10, buildActClaim should return null (cap exceeded)
        Map<String, Object> result = ActClaimTokenExchangeProvider.buildActClaim("agent-11", current);
        assertNull(result);
    }
}
