# Secret Provider

The server uses a simple provider pattern to retrieve the four configuration secrets it needs at
startup. The active provider is selected automatically based on environment variables.

## The Interface

```typescript
interface SecretsProvider {
  getSecrets(): Promise<AppSecrets>;
}
```

Every provider must return an `AppSecrets` object (`src/secrets.ts:14`):

| Field | Type | Required | Default |
|-------|------|----------|---------|
| `clientId` | `string` | yes | built-in public client ID |
| `tenantId` | `string` | no | `"common"` |
| `clientSecret` | `string` | no | — |
| `cloudType` | `CloudType` | no | `"global"` |

`clientSecret` is only needed for confidential-client flows (OBO mode via `--obo`).  
`cloudType` selects the Microsoft cloud environment (`"global"` or `"china"`).

## Built-in Providers

### 1. Environment Variables (default)

Used when `MS365_MCP_KEYVAULT_URL` is not set. Reads directly from the process environment.

| Environment variable | Maps to |
|----------------------|---------|
| `MS365_MCP_CLIENT_ID` | `clientId` |
| `MS365_MCP_TENANT_ID` | `tenantId` |
| `MS365_MCP_CLIENT_SECRET` | `clientSecret` |
| `MS365_MCP_CLOUD_TYPE` | `cloudType` |

**Relevant code:** `src/secrets.ts:31`

### 2. Azure Key Vault

Activated by setting `MS365_MCP_KEYVAULT_URL` to the vault URL
(e.g. `https://my-vault.vault.azure.net`).

Uses `DefaultAzureCredential` from `@azure/identity`, which tries the following credential chain
automatically: environment variables → workload identity → managed identity → Azure CLI.
No explicit credential configuration is needed when running on Azure infrastructure with a
managed identity assigned.

| Key Vault secret name | Maps to |
|-----------------------|---------|
| `ms365-mcp-client-id` | `clientId` (required) |
| `ms365-mcp-tenant-id` | `tenantId` |
| `ms365-mcp-client-secret` | `clientSecret` |
| `ms365-mcp-cloud-type` | `cloudType` |

`@azure/identity` and `@azure/keyvault-secrets` are optional dependencies — they are
dynamic-imported at call time so the server starts fine without them when Key Vault is not in use.

**Relevant code:** `src/secrets.ts:53`

## Provider Selection

The factory function `createSecretsProvider()` (`src/secrets.ts:98`) picks the provider:

```
MS365_MCP_KEYVAULT_URL set?
  yes → KeyVaultSecretsProvider
  no  → EnvironmentSecretsProvider
```

Secrets are fetched once and cached for the lifetime of the process (`src/secrets.ts:111`).
`clearSecretsCache()` (`src/secrets.ts:130`) resets the cache — used in tests.

## Adding a Custom Provider

The interface is intentionally minimal. To plug in another backend (AWS Secrets Manager,
HashiCorp Vault, GCP Secret Manager, 1Password, etc.):

1. Implement `SecretsProvider` in `src/secrets.ts` (or a separate file):

```typescript
class AwsSecretsManagerProvider implements SecretsProvider {
  async getSecrets(): Promise<AppSecrets> {
    // fetch from AWS and map to AppSecrets
    return { clientId: '...', tenantId: '...', cloudType: 'global' };
  }
}
```

2. Add a detection branch in `createSecretsProvider()`:

```typescript
function createSecretsProvider(): SecretsProvider {
  if (process.env.MS365_MCP_AWS_SECRET_ARN) {
    return new AwsSecretsManagerProvider();
  }
  if (process.env.MS365_MCP_KEYVAULT_URL) {
    return new KeyVaultSecretsProvider(process.env.MS365_MCP_KEYVAULT_URL);
  }
  return new EnvironmentSecretsProvider();
}
```

No other changes are required — the rest of the server consumes secrets only through
`getSecrets()` (`src/secrets.ts:117`), which calls whichever provider was selected.
