<h1 align="center">
  Acmebot for Microsoft Azure
</h1>
<p align="center">
  Automated ACME SSL/TLS certificate management built around Azure Key Vault
  (App Service / Container Apps / Application Gateway / Front Door / CDN / others)
</p>
<p align="center">
  <a href="https://github.com/projecthosts/keyvault-acmebot/actions/workflows/build.yml" rel="nofollow"><img src="https://github.com/projecthosts/keyvault-acmebot/workflows/Build/badge.svg" alt="Build" style="max-width: 100%;"></a>
  <a href="https://github.com/projecthosts/keyvault-acmebot/blob/master/LICENSE"><img src="https://badgen.net/github/license/projecthosts/keyvault-acmebot" alt="License" style="max-width: 100%;"></a>
  <a href="https://github.com/projecthosts/keyvault-acmebot/commits/master" rel="nofollow"><img src="https://badgen.net/github/last-commit/projecthosts/keyvault-acmebot" alt="Last commit" style="max-width: 100%;"></a>
  <a href="https://github.com/shibayan/keyvault-acmebot/wiki" rel="nofollow"><img src="https://badgen.net/badge/documentation/available/ff7733" alt="Documentation" style="max-width: 100%;"></a>
</p>

## Motivation

Acmebot was created to address the following requirements:

- Securely store SSL/TLS certificates with Azure Key Vault
- Centralize management of large numbers of certificates with a single Key Vault
- Easy to deploy and configure solution
- Highly reliable implementation
- Easy to monitor (Application Insights, Webhook)

Acmebot uses Azure Key Vault to provide secure and centralized management of ACME certificates.

## Feature Support

- Issue certificates for Zone Apex, Wildcard and SANs (multiple domains)
- Dedicated dashboard for easy certificate management
- Automated certificate renewal
- Support for ACME v2 compliant Certification Authorities
  - [Let's Encrypt](https://letsencrypt.org/)
  - [ZeroSSL](https://zerossl.com/features/acme/) (Requires EAB Credentials)
  - [Google Trust Services](https://pki.goog/) (Requires EAB Credentials)
  - [SSL.com](https://www.ssl.com/how-to/order-free-90-day-ssl-tls-certificates-with-acme/) (Requires EAB Credentials)
  - [Entrust](https://www.entrust.com/) (Requires EAB Credentials)
- Certificates can be used with many Azure services
  - Azure App Service (Web Apps / Functions / Containers)
  - Azure Container Apps (Include custom DNS suffix)
  - Front Door (Standard / Premium)
  - Application Gateway v2
  - API Management
  - SignalR Service (Premium)
  - Virtual Machine

## Custom Features in This Fork

This fork includes additional features not present in the upstream repository:

### Certificate Tags
Add custom metadata tags to Key Vault certificates during creation to organize and track certificates with flexible metadata (e.g., "Customer: Kraft", "Stage: production"). Tags are managed through the dashboard UI and stored directly in Azure Key Vault.

**Key Features:**
- Add/remove custom tags via dashboard UI
- Tags stored as Key Vault certificate metadata
- Protected system tags (Issuer, Endpoint, DnsProvider, DnsAlias) cannot be overwritten
- View certificate tags in certificate details modal

### Application Gateway Integration
Streamlined workflow for Application Gateway certificate deployments requiring specific Azure infrastructure tags. Provides a dedicated UI mode enforcing mandatory fields: EntraID, SubscriptionID, and KeyVaultName.

**Key Features:**
- Toggle "Application Gateway Integration" mode in dashboard
- Enforced validation for 3 required Azure infrastructure tags
- Compatible with custom tags feature (tags can be combined)
- Client-side validation for internal use

### DR Vault Replication
Opt-in certificate replication to a secondary Key Vault in a different region for disaster recovery. When enabled for a certificate, after issuance the complete certificate (including private key) is exported from the primary vault and imported into the DR vault, ensuring both vaults stay in sync.

**Key Features:**
- Per-certificate opt-in via "DR Vault Replication" toggle in the Add Certificate dialog
- Full certificate parity — cert, private key, and all tags are replicated to DR vault
- DR failure is blocking: if replication fails, the operation surfaces an error so issues are investigated rather than silently ignored
- Renewal inherits DR replication flag automatically — no manual re-enabling required

**Configuration:**
- Set `Acmebot:DrVaultBaseUrl` app setting to the DR Key Vault URI
- Grant the function app managed identity `Key Vault Certificates Officer` on the DR vault
- Grant the function app managed identity `Key Vault Secrets User` on the primary vault

## Deployment

| Azure (Public) | Azure Government |
| :---: | :---: |
| <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fprojecthosts%2Fkeyvault-acmebot%2Fmaster%2Fdeploy%2Fazuredeploy_consumption.bicep" target="_blank"><img src="https://aka.ms/deploytoazurebutton" /></a> | <a href="https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fprojecthosts%2Fkeyvault-acmebot%2Fmaster%2Fdeploy%2Fazuredeploy_consumption.bicep" target="_blank"><img src="https://aka.ms/deploytoazurebutton" /></a> |

**Post-deployment: Authentication required.** Fresh deployments from the ARM template do not have authentication configured. The dashboard will return 401 Unauthorized until an identity provider is set up:

1. Portal → Function App → **Authentication**
2. Click **Add identity provider** → Select **Microsoft**
3. Set **Unauthenticated requests** to `HTTP 302 Found (Redirect)`
4. Save

For detailed setup instructions, see: [Getting Started](https://github.com/shibayan/keyvault-acmebot/wiki/Getting-Started)

## Thanks

- [keyvault-acmebot](https://github.com/shibayan/keyvault-acmebot) by @shibayan and contributors
- [ACMESharp Core](https://github.com/PKISharp/ACMESharpCore) by @ebekker
- [Durable Functions](https://github.com/Azure/azure-functions-durable-extension) by @cgillum and contributors
- [DnsClient.NET](https://github.com/MichaCo/DnsClient.NET) by @MichaCo

## License

This project is licensed under the [Apache License 2.0](https://github.com/projecthosts/keyvault-acmebot/blob/master/LICENSE)
