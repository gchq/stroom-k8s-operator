# Identity provider (OpenID)

Stroom authenticates users with OpenID Connect, using either its own internal identity provider (IdP), with
`spec.identityProviderType: INTERNAL_IDP` (the default), or an **external** IdP, such as Keycloak, Microsoft Entra ID
or Amazon Cognito, with `EXTERNAL_IDP`.

## How the operator's scripts authenticate

The operator's node lifecycle scripts call the Stroom API on the node they run in: to enable the node and its jobs
when it starts, and to disable them and wait for its tasks to finish before it stops. With either IdP type, they
authenticate with a **Stroom API key** that the operator creates and renews:

1. The operator runs a Job that uses the Stroom CLI to create a Stroom user, `stroom-k8s-operator`, with the
   _Manage Nodes_, _Manage Jobs_ and _Manage Tasks_ permissions, and an API key for it that lasts 365 days. The Job
   writes the key into the Secret `stroom-<cluster>-api-key`.
2. Each node mounts the Secret at `/stroom/api-key`, and the scripts send the key with every call. A renewed key
   reaches running nodes without a restart.
3. The operator replaces the key 35 days before it expires.

The CLI works on Stroom's database, so the user exists only in Stroom. With an external IdP, nothing can sign in
interactively as that user. With `INTERNAL_IDP`, the operator creates the key before it creates or updates the nodes,
as the scripts have no other way to authenticate. With `EXTERNAL_IDP`, it creates and updates the nodes while the Job
runs, or fails and is retried: until there's a key, the scripts use a token from the IdP (see below), and the key
reaches the nodes once the Job writes it.

Stroom checks an API key before any IdP token, and doesn't contact the IdP to do so. So once the key exists, nodes
start, enable their jobs, and drain before they stop, even while an external IdP is unreachable.

!!! note "The API key Job needs the IdP"
    With `EXTERNAL_IDP`, every Stroom CLI command, like Stroom's own background work, runs as Stroom's processing
    user, whose identity is a client credentials token from the IdP. So the Job needs the IdP to be reachable, and
    Stroom's client needs the client credentials grant, which Stroom needs anyway. While the IdP is unreachable,
    the Job doesn't finish, and is retried until it does. Nodes keep using the current key, which is renewed well
    before it expires.

If the API key Secret is empty, the scripts fall back to a token from the IdP with the client credentials in
`spec.openId`, using Stroom's `/api/authproxy/v1/fetchClientCredsToken` endpoint, as earlier releases of the
operator did.

## The `spec.openId` setting

```yaml
spec:
  openId:
    clientId: stroom
    clientSecret:
      secretName: stroom-openid
      key: client-secret
```

`spec.openId` is needed with `EXTERNAL_IDP`. The operator passes these settings to every node as the environment
variables `STROOM_OPERATOR_OPENID_CLIENT_ID` and `STROOM_OPERATOR_OPENID_CLIENT_SECRET`. The bundled Stroom
configuration uses them as Stroom's own OpenID client ID and secret, and the lifecycle scripts use them only if
there's no API key.

The client needs:

- **Client authentication** (a confidential client with a secret).
- **The client credentials grant**, for Stroom's processing user. In Keycloak, turn on _Service accounts roles_
  for the client.
- **The authorisation code flow**, with the redirect URI `https://<ingress host>/api/auth/flow/v1/signin-oidc`,
  for interactive sign-in.
- **An audience** that Stroom accepts. Stroom checks the `aud` claim of access tokens against `clientId` (or
  `allowedAudiences`). Some IdPs, Keycloak included, need a mapper to put the client ID in the access token's
  `aud` claim.

If the scripts get `401` or `403` responses, see
[Troubleshooting](../operations/troubleshooting.md#authentication-failures-in-apilog).

## Configuring Stroom for the IdP

The bundled configuration sets `identityProviderType` from the `IDENTITY_PROVIDER_TYPE` environment variable,
defaulting to `INTERNAL_IDP`, and doesn't set an IdP discovery endpoint. To use an external IdP, provide your own
configuration through [`spec.configMapRef`](stroom-config.md) with at least:

```yaml
appConfig:
  security:
    authentication:
      openId:
        identityProviderType: EXTERNAL_IDP
        openIdConfigurationEndpoint: "https://keycloak.example.com/realms/stroom/.well-known/openid-configuration"
        clientId: ${STROOM_OPERATOR_OPENID_CLIENT_ID}
        clientSecret: ${STROOM_OPERATOR_OPENID_CLIENT_SECRET}
```

Stroom refuses to start with `EXTERNAL_IDP` and no `openIdConfigurationEndpoint`. For the other settings (logout
endpoint, scopes, audience and claim settings) and provider-specific instructions, see the Stroom documentation:

- [Stroom configuration for an external IdP](https://gchq.github.io/stroom-docs/docs/install-guide/setup/open-id/external-idp/stroom-configuration/)
- [KeyCloak](https://gchq.github.io/stroom-docs/docs/install-guide/setup/open-id/external-idp/keycloak/)
- [Creating the First Administrator](https://gchq.github.io/stroom-docs/docs/install-guide/setup/create-first-admin/),
  which you need to do because Stroom has no built-in administrator when using an external IdP. See also the
  [quick start](../getting-started/quick-start.md#7-create-the-first-administrator).

The [`external-idp`](https://github.com/gradata-systems/stroom-k8s-operator/tree/master/samples/external-idp) sample
is a complete configuration for Keycloak, with the realm's clients described in the
[samples README](https://github.com/gradata-systems/stroom-k8s-operator/tree/master/samples#keycloak).

## How tokens are handled

The scripts cache the token in `/stroom/auth/token`, a Pod-local volume, and request a new one shortly before it
expires. Failed token requests and API calls are logged, with the HTTP status and response, to
`/stroom/logs/k8s/api.log` in the node.
