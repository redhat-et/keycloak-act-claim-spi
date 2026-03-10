# Keycloak Act Claim SPI

A Keycloak SPI that implements RFC 8693 compliant token exchange with nested
`act` (actor) claims. Preserves delegation lineage across multi-hop
agent-to-agent communication chains.

## Prerequisites

- Java 21
- Maven 3.9.x
- Docker or Podman
- `oc` CLI authenticated to the OpenShift cluster

## Build the JAR

```bash
mvn clean package
```

## Run unit tests

```bash
mvn test
```

## Build and push the container image

The image must be `linux/amd64` for OpenShift. On Apple Silicon Macs, use
a remote Podman connection to an x86\_64 host to avoid slow QEMU emulation:

```bash
# On a remote x86_64 host (fast, native build)
make release PODMAN_CONNECTION=rhel

# Or locally with QEMU emulation (slow but works)
make release
```

Individual steps:

```bash
make image PODMAN_CONNECTION=rhel   # build only
make push  PODMAN_CONNECTION=rhel   # push only
```

Run `make help` for all available targets and variables.

## Deploy to OpenShift

```bash
make deploy
```

## Verify the SPI is loaded

```bash
make verify
```

Keycloak logs provider registration at startup. A successful load produces
a line containing `act-claim-exchange`.

## Quick iteration during development (no image rebuild)

```bash
make quick-deploy
```

Note: the copied JAR is lost when the pod restarts from an image pull. This
workflow is only for iterating on logic -- always build and push a proper
image before committing.

## Manual verification

After deployment, verify the SPI works end to end. A test script is
provided for convenience:

```bash
# Set environment variables (or create scripts/env.sh from the template)
cp scripts/env.sh.example scripts/env.sh
# Edit scripts/env.sh with your values
scripts/test-act-claim.sh
```

The script performs a two-hop token exchange simulating the delegation
chain `alice -> agent-service -> document-service` and verifies that
the `act` claim is correctly nested at each hop.

### Environment variables

| Variable | Description | Example |
|----------|-------------|---------|
| `KEYCLOAK_URL` | Keycloak base URL | `https://keycloak-spiffe-demo.apps.example.com` |
| `REALM` | Keycloak realm | `spiffe-demo` |
| `AGENT_CLIENT_ID` | First-hop client | `agent-service` |
| `AGENT_CLIENT_SECRET` | First-hop client secret | (from Keycloak) |
| `DOC_CLIENT_ID` | Second-hop client | `document-service` |
| `DOC_CLIENT_SECRET` | Second-hop client secret | (from Keycloak) |
| `KC_USERNAME` | Test user | `alice` |
| `KC_PASSWORD` | Test user password | `alice123` |

### Expected output

First-hop exchange -- `agent-service` acts on behalf of `alice`:

```json
{
  "preferred_username": "alice",
  "act": {
    "sub": "<agent-service-sa-uuid>"
  }
}
```

Second-hop exchange -- `document-service` acts on behalf of the chain:

```json
{
  "preferred_username": "alice",
  "act": {
    "sub": "<document-service-sa-uuid>",
    "act": {
      "sub": "<agent-service-sa-uuid>"
    }
  }
}
```

Note: the second-hop nesting requires that the actor token carries
the `act` claim from the prior hop. See the test script for details.
