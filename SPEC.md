# Keycloak act claim SPI — project specification

## Overview

Build a Keycloak Service Provider Interface (SPI) that implements RFC 8693 compliant
token exchange with nested `act` (actor) claims. The SPI extends Keycloak's built-in
token exchange to preserve delegation lineage across multi-hop agent-to-agent
communication chains, enabling Zero Trust policy enforcement based on the full
delegation path.

## Background and motivation

In agentic AI systems, an orchestrator agent may exchange a user's token to act on
their behalf, and then delegate further to a sub-agent (e.g. a summarizer). Each
hop must be traceable. RFC 8693 section 4.1 defines the `act` claim for this purpose:

```json
{
  "sub": "alice",
  "act": {
    "sub": "summarizer-agent",
    "act": {
      "sub": "orchestrator-agent"
    }
  }
}
```

Keycloak 26.x does not produce this nested structure during token exchange. This SPI
fills that gap.

## Target environment

- **Keycloak version:** 26.5.2 (upstream, not RHBK)
- **Deployment:** Plain Kubernetes `Deployment` on Red Hat OpenShift
- **Namespace:** `spiffe-demo`
- **Mode:** Development (single-node, local cache, H2 dev-file database)
- **Token exchange feature flag:** Already enabled (`kc.features = token-exchange`)
- **Java version:** 21 (LTS)
- **Build tool:** Maven 3.9.x

## Project structure

```
keycloak-act-claim-spi/
├── pom.xml
├── README.md
├── Dockerfile
├── src/
│   ├── main/
│   │   ├── java/
│   │   │   └── com/redhat/demo/keycloak/
│   │   │       ├── ActClaimTokenExchangeProvider.java
│   │   │       └── ActClaimTokenExchangeProviderFactory.java
│   │   └── resources/
│   │       └── META-INF/
│   │           └── services/
│   │               └── org.keycloak.protocol.oidc.tokenexchange.TokenExchangeProviderFactory
│   └── test/
│       └── java/
│           └── com/redhat/demo/keycloak/
│               └── ActClaimTokenExchangeProviderTest.java
└── k8s/
    └── keycloak-deployment-patch.yaml
```

## Maven configuration (`pom.xml`)

- **Group ID:** `com.redhat.demo.keycloak`
- **Artifact ID:** `keycloak-act-claim-spi`
- **Version:** `1.0.0-SNAPSHOT`
- **Packaging:** `jar`

### Dependencies (all `provided` scope — Keycloak supplies these at runtime)

```xml
<dependency>
  <groupId>org.keycloak</groupId>
  <artifactId>keycloak-core</artifactId>
  <version>26.5.2</version>
  <scope>provided</scope>
</dependency>
<dependency>
  <groupId>org.keycloak</groupId>
  <artifactId>keycloak-server-spi</artifactId>
  <version>26.5.2</version>
  <scope>provided</scope>
</dependency>
<dependency>
  <groupId>org.keycloak</groupId>
  <artifactId>keycloak-server-spi-private</artifactId>
  <version>26.5.2</version>
  <scope>provided</scope>
</dependency>
<dependency>
  <groupId>org.keycloak</groupId>
  <artifactId>keycloak-services</artifactId>
  <version>26.5.2</version>
  <scope>provided</scope>
</dependency>
```

### Test dependencies

```xml
<dependency>
  <groupId>org.junit.jupiter</groupId>
  <artifactId>junit-jupiter</artifactId>
  <version>5.11.4</version>
  <scope>test</scope>
</dependency>
<dependency>
  <groupId>org.mockito</groupId>
  <artifactId>mockito-core</artifactId>
  <version>5.15.2</version>
  <scope>test</scope>
</dependency>
```

### Build plugins

- `maven-compiler-plugin` targeting Java 21
- `maven-surefire-plugin` for JUnit 5
- The final JAR must NOT be a fat/uber JAR — all Keycloak dependencies are provided

## SPI implementation

### `ActClaimTokenExchangeProviderFactory`

Implements `org.keycloak.protocol.oidc.tokenexchange.TokenExchangeProviderFactory`.

Key requirements:

- `getId()` returns `"act-claim-exchange"`
- `create(KeycloakSession session)` returns a new `ActClaimTokenExchangeProvider` instance
- `order()` returns a positive integer (e.g. `100`) so this provider takes precedence
  over the built-in default
- No configuration needed — keep `init()` and `postInit()` as no-ops

### `ActClaimTokenExchangeProvider`

Implements `org.keycloak.protocol.oidc.tokenexchange.TokenExchangeProvider`.

Key requirements:

- `supports(TokenExchangeContext context)` returns `true` for all standard token
  exchange requests (do not narrow the scope — let it handle all exchanges)
- `exchange(TokenExchangeContext context)` contains the main logic:

  1. Perform the standard token exchange by delegating to
     `StandardTokenExchangeProvider` (or reuse its logic via composition, not
     inheritance, to keep the code maintainable)
  1. After the standard exchange produces a new `AccessToken`, extract the
     `actor_token` parameter from the HTTP request
  1. If `actor_token` is present:
     - Parse and validate it using `TokenVerifier` from `keycloak-core`
     - Extract the `sub` claim from the actor token
     - Extract the existing `act` claim from the actor token if present (for
       chain continuation)
     - Construct a new `Map<String, Object>` representing the nested `act`
       structure: `{ "sub": "<actor_sub>", "act": <existing_act_or_null> }`
     - Inject this map into the new access token using
       `token.setOtherClaims("act", actMap)`
  1. Return the response with the modified token

- `close()` is a no-op

### `act` claim construction logic

The nesting algorithm must handle three cases:

**Case 1 — first delegation (no existing `act` in actor token):**

```
actor_token.sub = "orchestrator"
actor_token.act = (absent)

result: { "sub": "orchestrator" }
```

**Case 2 — chain continuation (existing `act` in actor token):**

```
actor_token.sub = "summarizer"
actor_token.act = { "sub": "orchestrator" }

result: { "sub": "summarizer", "act": { "sub": "orchestrator" } }
```

**Case 3 — no actor token present:**

```
actor_token = (absent)

result: act claim is not added to the output token
```

### ServiceLoader registration file

File path (exactly):

```
src/main/resources/META-INF/services/org.keycloak.protocol.oidc.tokenexchange.TokenExchangeProviderFactory
```

File content (single line, no trailing whitespace):

```
com.redhat.demo.keycloak.ActClaimTokenExchangeProviderFactory
```

## Unit tests

Write tests in `ActClaimTokenExchangeProviderTest.java` using JUnit 5 and Mockito.

Test cases to cover:

- `testFactoryId()` — verifies `getId()` returns `"act-claim-exchange"`
- `testActClaimFirstHop()` — actor token has no `act` claim; result contains
  `act: {sub: "orchestrator"}`
- `testActClaimChaining()` — actor token has existing `act` claim; result contains
  nested structure
- `testNoActorToken()` — no actor token in request; result token has no `act` claim
- `testActClaimSubIsActorSub()` — verifies the `sub` inside `act` is the actor's
  `sub`, not the subject's `sub`

Since Keycloak's session and context objects are complex to instantiate outside a
running server, mock `TokenExchangeContext`, `KeycloakSession`, and `AccessToken`
using Mockito. Test the `act` claim construction logic in isolation by extracting it
into a package-private static helper method
`buildActClaim(String actorSub, Map<String, Object> existingAct)` that returns
`Map<String, Object>`. This makes the core logic testable without a Keycloak runtime.

## Dockerfile

Build a custom Keycloak image with the SPI JAR included:

```dockerfile
FROM quay.io/keycloak/keycloak:26.5.2

COPY target/keycloak-act-claim-spi-1.0.0-SNAPSHOT.jar /opt/keycloak/providers/

RUN /opt/keycloak/bin/kc.sh build
```

The `kc.sh build` step is required — it triggers Keycloak's Quarkus augmentation
phase which indexes and registers all providers found in the `providers/` directory.
Without it, the SPI JAR is ignored at runtime.

## OpenShift deployment patch

Provide a Kustomize strategic merge patch at `k8s/keycloak-deployment-patch.yaml`
that updates the existing `keycloak` Deployment in the `spiffe-demo` namespace to use
the custom image. The patch must only change the container image — leave all other
fields (env vars, ports, volumes) untouched.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: spiffe-demo
spec:
  template:
    spec:
      containers:
        - name: keycloak
          image: <registry>/keycloak-act-claim-spi:1.0.0-SNAPSHOT
```

Leave `<registry>` as a placeholder to be filled in by the developer.

## Build and deploy instructions (README.md)

The README must include the following sections with working shell commands:

### Prerequisites

- Java 21
- Maven 3.9.x
- Docker or Podman
- `oc` CLI authenticated to the OpenShift cluster

### Build the JAR

```bash
mvn clean package
```

### Run unit tests

```bash
mvn test
```

### Build and push the container image

```bash
podman build -t <registry>/keycloak-act-claim-spi:1.0.0-SNAPSHOT .
podman push <registry>/keycloak-act-claim-spi:1.0.0-SNAPSHOT
```

### Deploy to OpenShift

```bash
oc patch deployment keycloak -n spiffe-demo \
  --patch-file k8s/keycloak-deployment-patch.yaml
```

### Verify the SPI is loaded

```bash
oc logs deployment/keycloak -n spiffe-demo | grep -i "act-claim"
```

Keycloak logs provider registration at startup. A successful load produces a line
containing `act-claim-exchange`.

### Quick iteration during development (no image rebuild)

```bash
mvn clean package

oc cp target/keycloak-act-claim-spi-1.0.0-SNAPSHOT.jar \
  spiffe-demo/$(oc get pod -n spiffe-demo -l app=keycloak -o jsonpath='{.items[0].metadata.name}'):/opt/keycloak/providers/

oc rollout restart deployment/keycloak -n spiffe-demo
```

Note: the copied JAR is lost when the pod restarts from an image pull. This workflow
is only for iterating on logic — always build and push a proper image before
committing.

## Manual verification

After deployment, verify the SPI works end to end using `curl`.

### Step 1 — obtain a subject token (user login)

```bash
USER_TOKEN=$(curl -s -X POST \
  "http://<keycloak-url>/realms/<realm>/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=<client-id>" \
  -d "client_secret=<client-secret>" \
  -d "username=alice" \
  -d "password=alice-password" \
  | jq -r '.access_token')
```

### Step 2 — obtain an actor token (agent authentication)

```bash
ACTOR_TOKEN=$(curl -s -X POST \
  "http://<keycloak-url>/realms/<realm>/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=orchestrator-agent" \
  -d "client_secret=<agent-secret>" \
  | jq -r '.access_token')
```

### Step 3 — perform token exchange

```bash
EXCHANGED_TOKEN=$(curl -s -X POST \
  "http://<keycloak-url>/realms/<realm>/protocol/openid-connect/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=orchestrator-agent" \
  -d "client_secret=<agent-secret>" \
  -d "subject_token=${USER_TOKEN}" \
  -d "actor_token=${ACTOR_TOKEN}" \
  -d "actor_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "requested_token_type=urn:ietf:params:oauth:token-type:access_token" \
  | jq -r '.access_token')
```

### Step 4 — inspect the act claim

```bash
echo $EXCHANGED_TOKEN | cut -d'.' -f2 | base64 -d 2>/dev/null | jq '.act'
```

Expected output for a first-hop exchange:

```json
{
  "sub": "orchestrator-agent"
}
```

Expected output for a second-hop exchange (summarizer exchanging the already-exchanged
token):

```json
{
  "sub": "summarizer-agent",
  "act": {
    "sub": "orchestrator-agent"
  }
}
```

## Error handling requirements

- If `actor_token` is present but fails JWT parsing or signature verification, return
  HTTP 400 with a descriptive error message. Do not silently drop the actor token.
- If the `act` claim in the actor token is malformed (not a JSON object), log a
  warning and treat it as absent rather than failing the entire exchange.
- All exceptions must be caught and wrapped in `ErrorResponseException` using
  Keycloak's standard error response format.

## Logging requirements

Use `org.jboss.logging.Logger` (already on the classpath via Keycloak). Do not use
SLF4J or Log4j directly.

Log at the following levels:

- `DEBUG` — entry into `exchange()`, actor token sub value, constructed `act` claim
- `INFO` — successful exchange with `act` claim injected (include subject sub and
  actor sub)
- `WARN` — malformed `act` claim in actor token (include actor token sub)
- `ERROR` — unexpected exceptions before re-throwing

## Security considerations

- Never log the raw JWT token strings
- The actor token must be validated (signature, expiry, issuer) using Keycloak's
  `TokenVerifier` before trusting any claims from it
- The `act` claim depth should be capped at 10 levels to prevent unbounded nesting
  from a crafted token chain

## References

- [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
- [Keycloak token exchange documentation](https://www.keycloak.org/docs/latest/securing_apps/#token-exchange)
- [Keycloak SPI development guide](https://www.keycloak.org/docs/latest/server_development/#_providers)
- [TokenExchangeProvider interface source](https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/tokenexchange/TokenExchangeProvider.java)
- [TokenExchangeProviderFactory interface source](https://github.com/keycloak/keycloak/blob/main/services/src/main/java/org/keycloak/protocol/oidc/tokenexchange/TokenExchangeProviderFactory.java)
