# Design decision: act claim chaining in token exchange

## Context

We built a Keycloak SPI (`keycloak-act-claim-spi`) that injects RFC 8693
`act` (actor) claims during token exchange. The SPI works -- first-hop
exchanges produce the correct `act` claim. However, **multi-hop chaining
doesn't work yet** because of a design mismatch between how the SPI reads
delegation history and how AuthProxy performs exchanges.

## The delegation chain we want to support

```
Alice (user) -> agent-service -> summarizer-service -> document-service
```

At the final hop, `document-service` receives a token with:

```json
{
  "sub": "<alice-uuid>",
  "preferred_username": "alice",
  "aud": "document-service",
  "groups": ["engineering", "finance"],
  "act": {
    "sub": "<summarizer-service-sa>",
    "act": {
      "sub": "<agent-service-sa>"
    }
  }
}
```

This token tells document-service (and OPA) everything needed: Alice is
the original requester, she belongs to `finance` (so DOC-004 is
accessible), and the full delegation chain
`agent-service -> summarizer-service` is preserved for audit.

## How AuthProxy works today

AuthProxy (Envoy ext-proc in kagenti-extensions) does simple token
exchange at each hop:

- Takes the incoming `Authorization` bearer as `subject_token`
- Exchanges it for a new token with the target `audience`
- **Does not send `actor_token`** -- no delegation identity is captured
- Code: `kagenti-extensions/AuthBridge/AuthProxy/go-processor/main.go`,
  function `exchangeToken()`

## The problem

The SPI reads the `act` claim from the `actor_token` parameter (per
SPEC.md). But AuthProxy never sends an `actor_token`, so no `act` claims
are produced in practice. Even if we changed the SPI to read `act` from
the `subject_token` instead, we'd still lack the identity of the
*current* service in the chain.

## Two options

### Option 1 -- Read act from subject token (SPI-only change)

The SPI would read any existing `act` from the `subject_token` and
prepend the exchanging client's `client_id` (available from the exchange
context). No AuthProxy changes needed. But this deviates from RFC 8693,
which uses the `actor_token` parameter to carry the actor's identity.

### Option 2 -- Add actor\_token to AuthProxy (RFC 8693 compliant)

Each service's AuthProxy sidecar obtains its own `client_credentials`
token and sends it as `actor_token` alongside the `subject_token`. The
SPI reads `act` from the actor token and nests it. This follows RFC 8693
section 4.1 precisely.

Changes required:

- **AuthProxy (`go-processor`)**: On outbound requests, obtain a
  `client_credentials` token for the local service and include it as
  `actor_token` + `actor_token_type` parameters in the exchange call.
- **Keycloak SPI**: Already handles this correctly -- reads `act` from
  actor token and nests it.
- **Keycloak realm config**: Each client needs an audience mapper so
  exchanged tokens include downstream services in the `aud` claim (we
  confirmed this is needed -- without it, the next hop gets
  `"Client is not within the token audience"`).

## Current decision

We are leaning toward **Option 2** because:

1. It follows RFC 8693 faithfully
2. We are in contact with the AuthBridge developers and can propose the
   change upstream
3. The actor token explicitly identifies who is acting, rather than
   inferring it from the exchange client

## What's already working

- Keycloak SPI: deployed and tested on OpenShift (`spiffe-demo`
  namespace)
- First-hop exchange: `alice` token + `agent-service` actor -> produces
  `act: {sub: "<agent-service-sa>"}`
- Audience exchange: works when audience mappers are configured
- Test script: `scripts/test-act-claim.sh` in the SPI repo

## What needs to happen next

1. Decide Option 1 vs Option 2 (leaning Option 2)
2. If Option 2: modify AuthProxy's `exchangeToken()` to also send
   `actor_token`
3. Configure Keycloak audience mappers for the full chain:
   `agent-service -> summarizer-service -> document-service`
4. Restore the missing Keycloak clients (`summarizer-service`,
   `reviewer-service`, etc.) that were lost on restart
5. End-to-end test: Alice requests DOC-004 summarization, the token
   arrives at document-service with full `act` chain, OPA checks
   `finance` group membership and allows access

## Relevant code locations

| Component | Path |
|-----------|------|
| Keycloak SPI | `keycloak-act-claim-spi/` (this repo) |
| SPI provider | `src/main/java/.../ActClaimTokenExchangeProvider.java` |
| AuthProxy ext-proc | `kagenti-extensions/AuthBridge/AuthProxy/go-processor/main.go` |
| AuthProxy exchange fn | `exchangeToken()` in `main.go` (~line 285) |
| Test script | `keycloak-act-claim-spi/scripts/test-act-claim.sh` |
| Demo project | `zero-trust-agent-demo/` |
