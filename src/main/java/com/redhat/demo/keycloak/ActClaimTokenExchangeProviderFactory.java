package com.redhat.demo.keycloak;

import org.keycloak.Config;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.KeycloakSessionFactory;
import org.keycloak.protocol.oidc.TokenExchangeProvider;
import org.keycloak.protocol.oidc.TokenExchangeProviderFactory;

public class ActClaimTokenExchangeProviderFactory implements TokenExchangeProviderFactory {

    public static final String PROVIDER_ID = "act-claim-exchange";

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    @Override
    public TokenExchangeProvider create(KeycloakSession session) {
        return new ActClaimTokenExchangeProvider(session);
    }

    @Override
    public int order() {
        return 100;
    }

    @Override
    public void init(Config.Scope config) {
        // no-op
    }

    @Override
    public void postInit(KeycloakSessionFactory factory) {
        // no-op
    }

    @Override
    public void close() {
        // no-op
    }
}
