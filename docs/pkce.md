# PKCE — Proof Key for Code Exchange

PKCE (RFC 7636) is a security extension to the OAuth2 authorization code flow. It prevents
authorization code interception attacks.

## The Problem It Solves

In standard OAuth2, an attacker who intercepts the authorization code (e.g. via a malicious app
registered to the same redirect URI on a mobile device) can immediately exchange it for an access
token — the code alone is sufficient.

## How PKCE Works

```
Client                          Auth Server
  │                                  │
  │  1. Generate random secret       │
  │     code_verifier = random(32B)  │
  │     code_challenge = SHA256(code_verifier) encoded as base64url
  │                                  │
  │──── /authorize ─────────────────►│
  │     + code_challenge             │
  │     + code_challenge_method=S256 │
  │                                  │   Auth server stores code_challenge
  │                                  │   alongside the issued auth code
  │◄─── redirect with ?code=XYZ ────│
  │                                  │
  │──── /token ─────────────────────►│
  │     + code=XYZ                   │
  │     + code_verifier (the secret) │
  │                                  │   Server recomputes SHA256(code_verifier)
  │                                  │   and compares to stored code_challenge
  │◄─── access_token ───────────────│
```

The key property: an intercepted `code=XYZ` is useless without the `code_verifier`, which never
travels over the redirect channel. Even if an attacker captures the code, they cannot call
`/token` without the verifier.

## Two-Leg PKCE in This Server

This server acts as an OAuth proxy between an MCP client (e.g. Claude.ai) and Microsoft's
authorization server. Both legs need their own independent PKCE pair, but they must be linked
together across two HTTP requests (`/authorize` → `/token`).

```
MCP Client              ms-365-mcp-server            Microsoft
    │                          │                          │
    │  /authorize              │                          │
    │  + client_challenge ────►│                          │
    │                          │  generates server_verifier + server_challenge
    │                          │  stores { client_challenge, server_verifier }
    │                          │  in pkceStore, keyed by OAuth `state`
    │                          │──── /authorize ─────────►│
    │                          │     + server_challenge   │
    │◄─ redirect ?code=XYZ ───│◄─── redirect ?code=XYZ ─│
    │                          │                          │
    │  /token                  │                          │
    │  + code=XYZ              │                          │
    │  + client_verifier ─────►│                          │
    │                          │  recomputes SHA256(client_verifier)
    │                          │  finds matching entry in pkceStore
    │                          │  uses stored server_verifier
    │                          │──── /token ─────────────►│
    │                          │     + code=XYZ           │
    │                          │     + server_verifier    │
    │◄─ access_token ─────────│◄─── access_token ────────│
```

Two independent PKCE pairs are maintained:

- **Leg 1** (client ↔ server): the MCP client proves it initiated the flow
- **Leg 2** (server ↔ Microsoft): the server proves it initiated its own request to Microsoft

Without this split, the server would need to forward the client's `code_verifier` to Microsoft.
That is impossible because the server — not the client — is the party calling Microsoft's `/token`
endpoint. The two verifiers must differ because the two parties are different.

The two legs are linked by the OAuth `state` parameter, which is used as the key in the
in-memory `pkceStore` on `MicrosoftGraphServer`.

## Relevant Code

| What | Where |
|------|-------|
| `pkceStore` declaration | `src/server.ts:68` |
| `/authorize` — store client challenge, generate server challenge | `src/server.ts:383–426` |
| `/token` — verify client verifier, look up server verifier | `src/server.ts:519–539` |
| PKCE store capacity guard (max 1,000 entries) | `src/server.ts:400–410` |
| 10-minute TTL cleanup on each `/authorize` call | `src/server.ts:391–398` |

## Known Limitations

The `pkceStore` is in-process memory only. This means:

- It is lost on server restart; any in-flight authorization flows will fail.
- It does not work across multiple server instances (e.g. a load-balanced deployment). A shared
  store (Redis, database) would be required for horizontal scaling.
- The `/token` lookup is O(n): the server hashes the incoming `code_verifier` and scans all
  stored entries to find a matching `clientCodeChallenge`. A secondary index keyed on
  `clientCodeChallenge` would make this O(1).
