package com.redhat.demo.keycloak;

import java.util.HashMap;
import java.util.Map;

import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import org.jboss.logging.Logger;

import org.keycloak.OAuth2Constants;
import org.keycloak.OAuthErrorException;
import org.keycloak.TokenVerifier;
import org.keycloak.common.VerificationException;
import org.keycloak.models.KeycloakSession;
import org.keycloak.protocol.oidc.TokenExchangeContext;
import org.keycloak.protocol.oidc.TokenExchangeProvider;
import org.keycloak.protocol.oidc.tokenexchange.StandardTokenExchangeProvider;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.AccessTokenResponse;
import org.keycloak.services.ErrorResponseException;

public class ActClaimTokenExchangeProvider implements TokenExchangeProvider {

    private static final Logger LOG = Logger.getLogger(ActClaimTokenExchangeProvider.class);
    private static final int MAX_ACT_DEPTH = 10;

    private final KeycloakSession session;
    private final StandardTokenExchangeProvider delegate;

    public ActClaimTokenExchangeProvider(KeycloakSession session) {
        this.session = session;
        this.delegate = new StandardTokenExchangeProvider();
    }

    @Override
    public boolean supports(TokenExchangeContext context) {
        return true;
    }

    @Override
    public int getVersion() {
        return 1;
    }

    @Override
    public Response exchange(TokenExchangeContext context) {
        LOG.debug("Entering act-claim token exchange");

        Response response = delegate.exchange(context);

        String actorTokenString = context.getFormParams().getFirst(OAuth2Constants.ACTOR_TOKEN);
        if (actorTokenString == null || actorTokenString.isEmpty()) {
            LOG.debug("No actor_token present, returning standard exchange response");
            return response;
        }

        try {
            TokenVerifier<AccessToken> verifier = TokenVerifier.create(actorTokenString, AccessToken.class);
            verifier.withChecks(TokenVerifier.IS_ACTIVE);
            AccessToken actorToken = verifier.getToken();

            String actorSub = actorToken.getSubject();
            String actorClientId = actorToken.getIssuedFor(); // azp = SPIFFE ID
            LOG.debugv("Actor token sub: {0}, client_id: {1}", actorSub, actorClientId);

            // Read the existing act chain from the SUBJECT token (the token
            // being exchanged), not the actor token. The subject token carries
            // the delegation chain from previous hops.
            String subjectTokenString = context.getFormParams().getFirst(OAuth2Constants.SUBJECT_TOKEN);
            Map<String, Object> existingAct = null;
            if (subjectTokenString != null) {
                try {
                    AccessToken subjectToken = TokenVerifier.create(subjectTokenString, AccessToken.class)
                            .getToken();
                    Object existingActRaw = subjectToken.getOtherClaims().get("act");
                    if (existingActRaw instanceof Map) {
                        @SuppressWarnings("unchecked")
                        Map<String, Object> cast = (Map<String, Object>) existingActRaw;
                        existingAct = cast;
                        LOG.debugv("Found existing act chain in subject token: {0}", existingAct);
                    } else if (existingActRaw != null) {
                        LOG.warnv("Malformed act claim in subject token, treating as absent");
                    }
                } catch (VerificationException e) {
                    LOG.debugv("Could not parse subject token for act chain: {0}", e.getMessage());
                }
            }

            Map<String, Object> actClaim = buildActClaim(actorSub, actorClientId, existingAct);

            if (actClaim == null) {
                LOG.warn("Act claim depth exceeds maximum, not adding act claim");
                return response;
            }

            LOG.debugv("Constructed act claim: {0}", actClaim);

            if (response.getStatus() == Response.Status.OK.getStatusCode()) {
                Object entity = response.getEntity();
                if (entity instanceof AccessTokenResponse tokenResponse) {
                    String accessTokenStr = tokenResponse.getToken();
                    if (accessTokenStr != null) {
                        AccessToken newToken = session.tokens().decode(accessTokenStr, AccessToken.class);
                        newToken.setOtherClaims("act", actClaim);

                        String signedToken = session.tokens().encode(newToken);
                        tokenResponse.setToken(signedToken);

                        LOG.infov("Token exchange with act claim injected: subject={0}, actor={1}",
                                newToken.getSubject(), actorSub);

                        return Response.ok(tokenResponse, MediaType.APPLICATION_JSON_TYPE).build();
                    }
                }
            }

            return response;

        } catch (VerificationException e) {
            LOG.error("Actor token verification failed", e);
            throw new ErrorResponseException(
                    OAuthErrorException.INVALID_TOKEN,
                    "Invalid actor token: " + e.getMessage(),
                    Response.Status.BAD_REQUEST);
        } catch (ErrorResponseException e) {
            throw e;
        } catch (Exception e) {
            LOG.error("Unexpected error during act-claim token exchange", e);
            throw new ErrorResponseException(
                    OAuthErrorException.SERVER_ERROR,
                    "Token exchange failed: " + e.getMessage(),
                    Response.Status.INTERNAL_SERVER_ERROR);
        }
    }

    static Map<String, Object> buildActClaim(String actorSub, String actorClientId,
                                              Map<String, Object> existingAct) {
        if (actorSub == null) {
            return null;
        }

        if (existingAct != null && getActDepth(existingAct) >= MAX_ACT_DEPTH) {
            return null;
        }

        Map<String, Object> actClaim = new HashMap<>();
        actClaim.put("sub", actorSub);
        if (actorClientId != null) {
            actClaim.put("client_id", actorClientId);
        }
        if (existingAct != null) {
            actClaim.put("act", existingAct);
        }
        return actClaim;
    }

    @SuppressWarnings("unchecked")
    private static int getActDepth(Map<String, Object> act) {
        int depth = 1;
        Object nested = act.get("act");
        while (nested instanceof Map) {
            depth++;
            nested = ((Map<String, Object>) nested).get("act");
        }
        return depth;
    }

    @Override
    public void close() {
        // no-op
    }
}
