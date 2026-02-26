# DR KeyVault Replication Feature - Implementation Plan

## Overview

Add optional disaster recovery (DR) KeyVault replication for certificates. Users can select a checkbox during certificate creation to replicate the certificate to a secondary KeyVault for backup purposes.

## Architecture Summary

- **Primary KeyVault**: All certificates always created here (existing behavior)
- **DR KeyVault**: Optional second vault for disaster recovery replicas (configured via app settings)
  - **ALWAYS in a different Azure region** than Primary (e.g., Primary in East US, DR in West US)
  - Must be in the same Azure cloud environment (both in AzureCloud, or both in AzureUSGovernment)
  - Cross-region access within same cloud is fully supported by Azure Managed Identity
- **Per-Certificate Control**: Checkbox in UI to enable DR replication
- **Error Handling**: Fail-fast - if either vault fails, entire operation fails
- **Visibility**: UI only shows Primary vault; DR vault is invisible backup
- **Renewal**: Respects `DrReplicated` tag to maintain replication across renewals
- **Single DR Vault**: ONE DR vault for entire deployment (not per-certificate)

---

## Files to Modify

### 1. Options/AcmebotOptions.cs

**Purpose**: Add configuration for optional DR vault URL

**Change**: Add property after `VaultBaseUrl` (line 15)

```csharp
[Required]
public string VaultBaseUrl { get; set; }

public string DrVaultBaseUrl { get; set; }  // NEW: Optional DR KeyVault URL
```

**Notes**:
- Not marked as `[Required]` since DR vault is optional
- Should be full vault URL like primary (e.g., `https://dr-vault.vault.usgovcloudapi.net/`)

---

### 2. Functions/SharedActivity.cs

#### Change A: Add Private Fields

**Purpose**: Store DR client reference

**Location**: Top of class, modify existing field (around line 38)

```csharp
private readonly AcmebotOptions _options = options.Value;
private readonly CertificateClient _primaryClient;  // Rename from certificateClient
private readonly CertificateClient _drClient;  // NEW: May be null if not configured
```

#### Change B: Update Constructor

**Purpose**: Create DR client if configured, inject TokenCredential

**Location**: Constructor parameters (line 29-36)

**Add parameter**:
```csharp
public SharedActivity(
    LookupClient lookupClient,
    AcmeProtocolClientFactory acmeProtocolClientFactory,
    IEnumerable<IDnsProvider> dnsProviders,
    CertificateClient certificateClient,
    TokenCredential credential,  // NEW: For DR client creation
    WebhookInvoker webhookInvoker,
    IOptions<AcmebotOptions> options,
    ILogger<SharedActivity> logger)
{
    _options = options.Value;
    _primaryClient = certificateClient;

    // Create DR client if DrVaultBaseUrl is configured
    if (!string.IsNullOrEmpty(_options.DrVaultBaseUrl))
    {
        _drClient = new CertificateClient(new Uri(_options.DrVaultBaseUrl), credential);
    }
    // else _drClient remains null
}
```

**Notes**:
- `TokenCredential` is already registered in DI (Program.cs line 67-77)
- DR client created lazily only if configured
- All references to `certificateClient` in class must be changed to `_primaryClient`

#### Change C: Modify FinalizeOrder() Method

**Purpose**: Replicate certificate to DR vault if requested

**Location**: Lines 371-399 (certificate creation section)

**Current code** (lines 371-399):
```csharp
byte[] csr;

try
{
    var certificatePolicy = certificatePolicyItem.ToCertificatePolicy();
    var metadata = certificatePolicyItem.ToCertificateMetadata(_options.Endpoint);

    var certificateOperation = await certificateClient.StartCreateCertificateAsync(
        certificatePolicyItem.CertificateName,
        certificatePolicy,
        enabled: true,
        tags: metadata,
        cancellationToken: default
    );

    csr = certificateOperation.Properties.Csr;
}
catch (Azure.RequestFailedException ex) when (ex.Status == (int)HttpStatusCode.Conflict)
{
    var certificateOperation = await certificateClient.GetCertificateOperationAsync(certificatePolicyItem.CertificateName);
    csr = certificateOperation.Properties.Csr;
}

// Order 
var acmeProtocolClient = await acmeProtocolClientFactory.CreateClientAsync();
return await acmeProtocolClient.FinalizeOrderAsync(orderDetails.Payload.Finalize, csr);
```

**New code**:
```csharp
byte[] csr;

// Move policy/metadata creation outside try/catch so DR code can access them
var certificatePolicy = certificatePolicyItem.ToCertificatePolicy();
var metadata = certificatePolicyItem.ToCertificateMetadata(_options.Endpoint);

// Add DR replication tag to metadata if DR requested
if (certificatePolicyItem.UseDrReplication && _drClient != null)
{
    metadata["DrReplicated"] = "true";
}

try
{
    // Always create in primary vault
    var certificateOperation = await _primaryClient.StartCreateCertificateAsync(
        certificatePolicyItem.CertificateName,
        certificatePolicy,
        enabled: true,
        tags: metadata,
        cancellationToken: default
    );

    csr = certificateOperation.Properties.Csr;
}
catch (Azure.RequestFailedException ex) when (ex.Status == (int)HttpStatusCode.Conflict)
{
    // Cert already exists - retrieve existing operation (handles manual retry after DR failure)
    var certificateOperation = await _primaryClient.GetCertificateOperationAsync(certificatePolicyItem.CertificateName);
    csr = certificateOperation.Properties.Csr;
}

// CRITICAL: DR creation OUTSIDE try/catch so it runs even when conflict handler fires
// This enables manual retry after DR failures: Dashboard → Certificate Details → Renew button
if (certificatePolicyItem.UseDrReplication && _drClient != null)
{
    try
    {
        await _drClient.StartCreateCertificateAsync(
            certificatePolicyItem.CertificateName,
            certificatePolicy,
            enabled: true,
            tags: metadata,
            cancellationToken: default
        );

        logger.LogInformation("Certificate {CertificateName} replicated to DR vault",
            certificatePolicyItem.CertificateName);
    }
    catch (Exception ex)
    {
        logger.LogError(ex, "Failed to replicate certificate {CertificateName} to DR vault",
            certificatePolicyItem.CertificateName);
        throw; // Fail-fast: DR failure = total failure
    }
}

// Order の最終処理を実行する
var acmeProtocolClient = await acmeProtocolClientFactory.CreateClientAsync();
return await acmeProtocolClient.FinalizeOrderAsync(orderDetails.Payload.Finalize, csr);
```

**Notes**:
- `certificatePolicy` and `metadata` moved outside try/catch so DR code can access them
- DR tag added to metadata before Primary creation (ensures both vaults have same tags)
- Primary creation wrapped in existing try/catch with conflict handler
- Conflict handler updated to use `_primaryClient` instead of `certificateClient`
- **CRITICAL PLACEMENT**: DR creation code is **outside** the Primary try/catch block
  - This ensures DR creation runs even when conflict handler fires (manual retry scenario)
  - Enables recovery workflow: Fix DR issue → Dashboard → Details → Renew
  - Conflict handler reuses existing Primary cert, DR creation proceeds normally
- CSR comes from Primary vault (either new creation or existing cert via conflict handler)
- DR creation uses same `certificatePolicy` and `metadata` as Primary
- Exception thrown if DR fails (fail-fast strategy)
- Entire ACME finalization continues with CSR from Primary vault

#### Change D: Update All CertificateClient References

**Purpose**: Use `_primaryClient` instead of injected parameter

**Locations**: All methods that currently use `certificateClient` parameter:
- `GetExpiringCertificates()` (line 43, 59)
- `GetAllCertificates()` (search for usage)
- `GetCertificate()` (if exists)
- Any other certificate read operations

**Change**: Replace `certificateClient` → `_primaryClient`

**Rationale**: All read operations should only query Primary vault (DR is invisible backup)

---

### 3. Models/CertificatePolicyItem.cs

**Purpose**: Add property to indicate if DR replication is requested

**Change**: Add property after `Tags` (line 38)

```csharp
[JsonPropertyName("tags")]
public IDictionary<string, string> Tags { get; set; }

[JsonPropertyName("useDrReplication")]
public bool UseDrReplication { get; set; }
```

**Notes**:
- Boolean defaults to `false` if not provided in request
- Sent from frontend when user selects DR checkbox

---

### 4. Internal/CertificateExtensions.cs

**Purpose**: Add DR replication support for certificate renewal flow

This file contains extension methods that convert certificates between different representations. The `ToCertificatePolicyItem()` method is used during renewal to build a new certificate request from an existing certificate.

#### Change A: Add DrReplicated Constant

**Location**: After line 102 (with other constant definitions)

```csharp
private const string IssuerKey = "Issuer";
private const string EndpointKey = "Endpoint";
private const string DnsProviderKey = "DnsProvider";
private const string DnsAliasKey = "DnsAlias";
private const string DrReplicatedKey = "DrReplicated";  // NEW
```

#### Change B: Add Helper Method

**Location**: After line 112 (with other helper methods)

```csharp
private static bool TryGetDrReplicated(this IDictionary<string, string> tags, out string drReplicated)
    => tags.TryGetValue(DrReplicatedKey, out drReplicated);
```

#### Change C: Update ToCertificatePolicyItem() for Renewal

**Purpose**: Read `DrReplicated` tag from existing cert and set `UseDrReplication` flag

**Location**: Line 65 (inside `ToCertificatePolicyItem` method)

**Current code** (lines 56-66):
```csharp
return new CertificatePolicyItem
{
    CertificateName = certificate.Name,
    DnsNames = dnsNames.Length > 0 ? dnsNames : new[] { certificate.Policy.Subject[3..] },
    DnsProviderName = certificate.Properties.Tags.TryGetDnsProvider(out var dnsProviderName) ? dnsProviderName : "",
    KeyType = certificate.Policy.KeyType?.ToString(),
    KeySize = certificate.Policy.KeySize,
    KeyCurveName = certificate.Policy.KeyCurveName?.ToString(),
    ReuseKey = certificate.Policy.ReuseKey,
    DnsAlias = certificate.Properties.Tags.TryGetDnsAlias(out var dnsAlias) ? dnsAlias : ""
};
```

**New code**:
```csharp
return new CertificatePolicyItem
{
    CertificateName = certificate.Name,
    DnsNames = dnsNames.Length > 0 ? dnsNames : new[] { certificate.Policy.Subject[3..] },
    DnsProviderName = certificate.Properties.Tags.TryGetDnsProvider(out var dnsProviderName) ? dnsProviderName : "",
    KeyType = certificate.Policy.KeyType?.ToString(),
    KeySize = certificate.Policy.KeySize,
    KeyCurveName = certificate.Policy.KeyCurveName?.ToString(),
    ReuseKey = certificate.Policy.ReuseKey,
    DnsAlias = certificate.Properties.Tags.TryGetDnsAlias(out var dnsAlias) ? dnsAlias : "",
    UseDrReplication = certificate.Properties.Tags.TryGetDrReplicated(out var drReplicated) && drReplicated == "true"  // NEW
};
```

**Notes**:
- Checks if `DrReplicated` tag exists and equals "true"
- If tag present, sets `UseDrReplication = true` for renewal
- If tag absent or any other value, defaults to `false`
- This ensures DR replication setting persists across renewals

#### Change D: Exclude DrReplicated from Custom Tags

**Purpose**: `DrReplicated` is a system-managed tag, not a user custom tag

**Location 1**: Line 29 (in `ToCertificateItem` method - excludes from display)

**Current code**:
```csharp
var customTags = certificate.Properties.Tags
    .Where(tag => tag.Key != IssuerKey && tag.Key != EndpointKey && tag.Key != DnsProviderKey && tag.Key != DnsAliasKey)
    .ToDictionary(tag => tag.Key, tag => tag.Value);
```

**New code**:
```csharp
var customTags = certificate.Properties.Tags
    .Where(tag => tag.Key != IssuerKey && tag.Key != EndpointKey && tag.Key != DnsProviderKey && tag.Key != DnsAliasKey && tag.Key != DrReplicatedKey)
    .ToDictionary(tag => tag.Key, tag => tag.Value);
```

**Location 2**: Line 89 (in `ToCertificateMetadata` method - prevents overwriting)

**Current code**:
```csharp
// Skip reserved keys to avoid conflicts
if (tag.Key != IssuerKey && tag.Key != EndpointKey && tag.Key != DnsProviderKey && tag.Key != DnsAliasKey)
{
    metadata[tag.Key] = tag.Value;
}
```

**New code**:
```csharp
// Skip reserved keys to avoid conflicts
if (tag.Key != IssuerKey && tag.Key != EndpointKey && tag.Key != DnsProviderKey && tag.Key != DnsAliasKey && tag.Key != DrReplicatedKey)
{
    metadata[tag.Key] = tag.Value;
}
```

**Notes**:
- Ensures `DrReplicated` is treated as reserved system tag like `Issuer`, `Endpoint`, etc.
- Users cannot see or override `DrReplicated` tag via custom tags feature
- Maintains separation between system and user tags

---

### 5. wwwroot/dashboard/index.html

#### Change A: Add DR Checkbox UI

**Purpose**: Allow users to select DR replication

**Location**: After Application Gateway Integration section (after line 257)

```html
<!-- DR KeyVault Replication -->
<div class="field is-horizontal">
  <div class="field-label">
    <label class="label">Replicate to DR KeyVault?</label>
  </div>
  <div class="field-body">
    <div class="field is-narrow">
      <div class="control">
        <label class="radio">
          <input type="radio" v-model="add.useDrReplication" :value="true">
          Yes
        </label>
        <label class="radio">
          <input type="radio" v-model="add.useDrReplication" :value="false">
          No
        </label>
      </div>
    </div>
  </div>
</div>
```

**Notes**:
- Positioned between "Application Gateway Integration" and "Use Advanced Options"
- Follows same radio button pattern as other yes/no options
- Always visible (no conditional rendering)

#### Change B: Add Data Property

**Purpose**: Store DR replication state

**Location**: In Vue `data()` section (around line 607, after `appGwKeyVaultName`)

```javascript
appGwKeyVaultName: "",
useDrReplication: false,  // NEW: DR KeyVault replication flag
```

**Notes**:
- Defaults to `false` (no DR replication)
- Boolean value matches radio button binding

#### Change C: Include in POST Request

**Purpose**: Send DR flag to backend

**Location**: In `addCertificate()` method (around line 730)

```javascript
const postData = {
  certificateName: this.add.certificateName || null,
  dnsNames: this.add.dnsNames,
  acmeEndpoint: this.add.acmeEndpoint,
  useDrReplication: this.add.useDrReplication,  // NEW
  // ... existing fields (issuer, dnsProvider, tags, etc.)
};
```

#### Change D: Reset on Modal Open

**Purpose**: Clear DR flag when opening Add Certificate modal

**Location**: In `openAdd()` method (around line 782)

```javascript
this.add.appGwKeyVaultName = "";
this.add.useDrReplication = false;  // NEW: Reset DR flag
```

---

## Data Flow

### Certificate Creation Flow

1. **User Action**: Opens "Add Certificate" modal, selects "Replicate to DR KeyVault? Yes"
2. **Frontend**: User clicks Add → `addCertificate()` method called
3. **HTTP Request**: POST `/api/certificate` with JSON body including `useDrReplication: true`
4. **Function Entry**: `AddCertificate.HttpStart()` receives `CertificatePolicyItem` with `UseDrReplication = true`
5. **Orchestration**: Durable Functions orchestration starts certificate workflow
6. **Certificate Creation**: `SharedActivity.FinalizeOrder()` called:
   - Adds `DrReplicated: "true"` to metadata dictionary
   - Creates certificate in Primary vault with all metadata/tags
   - If successful, creates identical certificate in DR vault with same metadata/tags
   - If DR creation fails, throws exception (orchestration fails)
   - Returns CSR from Primary vault operation to continue ACME flow
7. **ACME Finalization**: CSR sent to ACME server, certificate finalized
8. **Result**: Certificate exists in both Primary and DR vaults with `DrReplicated: "true"` tag

### Certificate Renewal Flow

1. **Timer Trigger**: `RenewCertificates.Orchestrator()` runs daily (RenewCertificates.cs:15)
2. **Discovery**: Calls `SharedActivity.GetExpiringCertificates()` to query Primary vault only
3. **For Each Expiring Certificate**:
   - Calls `SharedActivity.GetCertificatePolicy(certificateName)` (SharedActivity.cs:105)
   - Method retrieves cert from KeyVault: `certificateClient.GetCertificateAsync(certificateName)`
   - Converts to policy: `certificate.ToCertificatePolicyItem()` (CertificateExtensions.cs:52)
   - **Tag Check**: `ToCertificatePolicyItem()` reads `DrReplicated` tag from certificate
   - If `DrReplicated: "true"` exists → Sets `UseDrReplication = true`
   - If tag absent → `UseDrReplication = false`
4. **Renewal**: Calls `SharedOrchestrator.IssueCertificate` with constructed `CertificatePolicyItem`
5. **Certificate Creation**: Eventually calls `FinalizeOrder()` - same flow as new cert creation
6. **Result**: Certificate renewed in same vault(s) as original creation

**See "Files to Modify" section 4 (CertificateExtensions.cs) for implementation details.**

---

## Configuration

### Application Settings

**Existing** (required):
```json
{
  "Acmebot": {
    "VaultBaseUrl": "https://primary-vault.vault.azure.net/",
    "Contacts": "admin@example.com",
    "Endpoint": "https://acme-v02.api.letsencrypt.org/directory",
    "Environment": "AzureCloud"
  }
}
```

**With DR Vault** (optional - same cloud, different region):
```json
{
  "Acmebot": {
    "VaultBaseUrl": "https://primary-vault-eastus.vault.azure.net/",
    "DrVaultBaseUrl": "https://dr-vault-westus.vault.azure.net/",
    "Contacts": "admin@example.com",
    "Endpoint": "https://acme-v02.api.letsencrypt.org/directory",
    "Environment": "AzureCloud"
  }
}
```

**Notes**:
- Both vaults must be in same Azure cloud environment
- DR vault must be in different Azure region than Primary (DR requirement)
- Vault URLs have same suffix (`.vault.azure.net` for AzureCloud, `.vault.usgovcloudapi.net` for AzureUSGovernment)
- Different KeyVault names help identify region placement (e.g., `-eastus` vs `-westus`)

### Azure Managed Identity Permissions

**Primary KeyVault** (existing):
- Certificate: Get, List, Create, Update, Delete

**DR KeyVault** (NEW - required if DrVaultBaseUrl configured):
- Certificate: Create, Update
- Note: Read permissions NOT required (DR is write-only from app perspective)

**Configuration Steps**:
1. Assign Function App managed identity to DR KeyVault
2. Grant "Key Vault Certificates Officer" role or equivalent custom role
3. Test access before deploying DR feature

---

## Error Scenarios & Handling

### Scenario 1: Primary Succeeds, DR Fails

**Trigger**: Network issue, permission error, or DR vault unavailable

**Behavior**:
- Primary certificate created successfully
- DR replication throws exception
- Exception propagated (fail-fast)
- Durable Functions orchestration fails

**Question**: Does orchestration retry from beginning, or is Primary cert orphaned?

**Possible outcomes**:
- **Option A**: Orchestration retries entire flow → Primary cert may hit conflict (line 388)
- **Option B**: Orchestration fails permanently → Manual cleanup required

**Mitigation considerations**:
- Add explicit rollback: Delete Primary cert if DR fails?
- Accept orphaned cert: DR vault can be synced manually later?
- Add retry with exponential backoff for DR only?

**Recommended**: Test actual orchestration behavior to determine if rollback needed.

---

### Scenario 2: DR Vault Not Configured

**Trigger**: `DrVaultBaseUrl` not in app settings, or empty string

**Behavior**:
- `_drClient` is `null`
- User selects "Replicate to DR? Yes"
- Backend checks: `certificatePolicyItem.UseDrReplication && _drClient != null`
- Condition fails, DR creation silently skipped
- Certificate created only in Primary vault

**Current approach**: Silent skip (no error)

**Alternative approaches**:
- **Option A**: Return validation error if DR requested but not configured
- **Option B**: Add API endpoint to check if DR configured, hide checkbox if unavailable
- **Option C**: Show warning in UI if DR requested but not configured

**Recommended**: Keep simple (silent skip) for now, document in admin guide.

---

### Scenario 3: Certificate Already Exists in DR Vault

**Trigger**: Certificate with same name already exists in DR vault

**Behavior**:
- Primary creation succeeds (or hits conflict handler line 388)
- DR creation throws `RequestFailedException` with status code 409 (Conflict)
- Exception propagated (fail-fast)

**Question**: Should we add same conflict handling for DR as Primary?

**Current Primary conflict handling** (lines 388-393):
```csharp
catch (Azure.RequestFailedException ex) when (ex.Status == (int)HttpStatusCode.Conflict)
{
    var certificateOperation = await certificateClient.GetCertificateOperationAsync(...);
    csr = certificateOperation.Properties.Csr;
}
```

**Possible DR approaches**:
- **Option A**: Let conflict throw (fail-fast) → Admin must manually resolve
- **Option B**: Catch conflict, retrieve existing DR cert operation (mirror Primary logic)
- **Option C**: Catch conflict, assume DR already has cert, continue silently

**Recommended**: Option B (mirror Primary logic) for consistency.

---

### Scenario 4: DR Vault Permissions Missing

**Trigger**: Managed identity doesn't have Certificate Create permissions on DR vault

**Behavior**:
- Primary creation succeeds
- DR creation throws `RequestFailedException` with 403 Forbidden
- Exception logged with clear message
- Orchestration fails

**Logging**:
```
Failed to replicate certificate example.com to DR vault:
  Azure.RequestFailedException: Status: 403 (Forbidden)
```

**Resolution**: Admin grants permissions, retries certificate creation.

---

### Scenario 5: Cross-Region Access

**Trigger**: Primary and DR vaults in different Azure regions (e.g., Primary in East US, DR in West US)

**Behavior**:
- Both vaults use same `TokenCredential` (DefaultAzureCredential)
- DefaultAzureCredential obtains tokens from same Azure AD tenant
- ✅ Cross-region access within same cloud is fully supported
- DR write operations may have slightly higher latency due to region distance (acceptable)

**Requirements**:
- Both vaults must be in same Azure cloud environment (both AzureCloud, or both AzureUSGovernment)
- Managed identity must have Certificate permissions on both vaults
- If KeyVault firewall enabled, must allow Function App's outbound IPs in both vault regions

**Note**: Cross-cloud scenarios (Primary in AzureCloud, DR in AzureUSGovernment) are OUT OF SCOPE and NOT SUPPORTED.

---

## Testing Checklist

### Basic Functionality
- [ ] Create cert with DR checkbox OFF → Only in Primary vault
- [ ] Create cert with DR checkbox ON → Exists in both vaults
- [ ] Verify Primary cert has `DrReplicated: "true"` tag
- [ ] Verify DR cert has `DrReplicated: "true"` tag
- [ ] Verify DR cert has identical content (thumbprint, expiry, etc.)
- [ ] Verify custom tags appear on both certs
- [ ] Verify Application Gateway tags appear on both certs (if AppGW mode enabled)
- [ ] Verify system tags (Issuer, Endpoint, DnsProvider) appear on both certs

### Certificate Renewal
- [ ] Cert with `DrReplicated: true` tag → Renews in both vaults
- [ ] Cert without `DrReplicated` tag → Renews only in Primary
- [ ] Renewed cert preserves `DrReplicated: "true"` tag
- [ ] Renewed cert in DR has same expiry as Primary

### Error Handling
- [ ] DR vault has invalid URL → Operation fails with clear error
- [ ] DR vault permissions missing → Operation fails with 403 error
- [ ] DR vault unreachable/offline → Operation fails with timeout
- [ ] Primary succeeds + DR fails → Verify Primary cert state (orphaned or rolled back?)
- [ ] Certificate name conflict in DR → Test conflict handling

### Configuration Scenarios
- [ ] `DrVaultBaseUrl` not configured → DR creation skipped gracefully
- [ ] `DrVaultBaseUrl` is empty string → Treated as not configured
- [ ] Both vaults in same Azure cloud, different regions (e.g., East US + West US) → Works correctly
- [ ] Both vaults in AzureUSGovernment, different regions (e.g., USGov Virginia + USGov Arizona) → Works correctly
- [ ] Cross-cloud scenarios (Primary in AzureCloud, DR in AzureUSGovernment) → NOT SUPPORTED (out of scope)

### UI/UX
- [ ] DR checkbox appears in Add Certificate modal
- [ ] DR checkbox defaults to "No" (false)
- [ ] DR checkbox state resets when modal closed and reopened
- [ ] DR checkbox works alongside Application Gateway mode
- [ ] DR checkbox works alongside Advanced Options (custom tags, cert name, etc.)
- [ ] Dashboard shows only Primary vault certs (DR invisible)
- [ ] Certificate details modal does not show DR vault information

### Integration with Existing Features
- [ ] DR works with custom certificate tags feature
- [ ] DR works with Application Gateway Integration feature
- [ ] DR works with different ACME endpoints (Let's Encrypt, ZeroSSL, etc.)
- [ ] DR works with wildcard certificates
- [ ] DR works with SANs (multi-domain) certificates
- [ ] DR works with different DNS providers

---

## Open Questions

### 1. Orchestration Rollback Behavior ✅ RESOLVED

**Question**: If Primary cert creation succeeds but DR fails, does Durable Functions orchestration automatically retry from the beginning (potentially creating duplicate Primary cert), or does it fail permanently leaving orphaned Primary cert?

**Answer**: **No explicit rollback logic needed.** The existing conflict handler provides perfect retry semantics for DR failures.

**What Happens When Primary Succeeds but DR Fails:**

1. Primary cert created in KeyVault with `DrReplicated: "true"` tag ✅
2. DR replication throws exception (network issue, permissions, vault unavailable, etc.) ❌
3. Exception is **not** `RetriableOrchestratorException`, so **no automatic retry**
4. Orchestration fails, error logged to Application Insights
5. **Primary cert remains in KeyVault** (orphaned without DR replica)

**Why No Rollback Is Needed:**

The existing conflict handler in `SharedActivity.FinalizeOrder()` (line 388-393) provides the solution:

```csharp
catch (Azure.RequestFailedException ex) when (ex.Status == (int)HttpStatusCode.Conflict)
{
    var certificateOperation = await certificateClient.GetCertificateOperationAsync(certificateName);
    csr = certificateOperation.Properties.Csr;  // Reuse existing cert's CSR
}
```

**Manual Retry Flow (via Web UI):**

1. Admin sees error in Application Insights logs
2. Admin fixes underlying issue (restores DR vault connectivity, fixes permissions, etc.)
3. Admin opens dashboard → Finds certificate → Clicks "Details" → Clicks **"Renew" button**
4. Backend receives POST to `/api/certificate/{certificateName}/renew`
5. Renewal orchestration starts:
   - Reads existing cert from KeyVault
   - Cert has `DrReplicated: "true"` tag
   - Sets `UseDrReplication = true` (via `ToCertificatePolicyItem()`)
   - Gets to `FinalizeOrder()`
   - Attempts to create Primary cert
   - **Conflict! (409)** - cert already exists
   - **Conflict handler fires** → Retrieves existing cert operation & CSR
   - **DR creation runs** (now succeeds because issue fixed)
   - Certificate finalized with ACME
6. Success! Both vaults now have certificate ✅

**Critical Implementation Detail:**

DR creation code **must be outside** the Primary conflict try/catch block to ensure it runs even when conflict handler fires:

```csharp
byte[] csr;

try
{
    // Create in Primary vault
    var certificateOperation = await _primaryClient.StartCreateCertificateAsync(...);
    csr = certificateOperation.Properties.Csr;
}
catch (Azure.RequestFailedException ex) when (ex.Status == (int)HttpStatusCode.Conflict)
{
    // Reuse existing cert
    var certificateOperation = await _primaryClient.GetCertificateOperationAsync(certificateName);
    csr = certificateOperation.Properties.Csr;
}

// IMPORTANT: DR creation OUTSIDE try/catch so it runs even on conflict
if (certificatePolicyItem.UseDrReplication && _drClient != null)
{
    await _drClient.StartCreateCertificateAsync(...);
}
```

**Recovery Workflow Summary:**

1. See error in logs/monitoring
2. Fix underlying DR issue
3. Dashboard → Certificate Details → Renew
4. Done!

**Decision**: Manual retry via UI is sufficient. No need for automatic retry logic or explicit rollback.

---

### 2. Renewal Flow Entry Point ✅ RESOLVED

**Question**: Where does the renewal process build `CertificatePolicyItem` from existing certificate properties?

**Answer**: Found the exact location - `Internal/CertificateExtensions.cs:52-67`

**Renewal Flow Traced**:
```
Timer Trigger (daily)
    ↓
RenewCertificates.Orchestrator() [RenewCertificates.cs:15]
    ↓
GetExpiringCertificates() [SharedActivity.cs:41]
    ↓ (for each expiring cert)
GetCertificatePolicy(certificateName) [SharedActivity.cs:105]
    ↓
certificate.ToCertificatePolicyItem() [CertificateExtensions.cs:52]
    ↓
Returns CertificatePolicyItem
    ↓
Calls SharedOrchestrator.IssueCertificate
    ↓
Eventually calls FinalizeOrder() [SharedActivity.cs:371]
```

**Key Finding**: The `ToCertificatePolicyItem()` extension method in `CertificateExtensions.cs` converts existing certificates to `CertificatePolicyItem` for renewal. This is where we need to read the `DrReplicated` tag and set `UseDrReplication` property.

**Additional changes identified**:
- Need to add `DrReplicated` to reserved tags list (exclude from custom tags display)
- Need helper method `TryGetDrReplicated()` following existing pattern
- Need constant `DrReplicatedKey = "DrReplicated"`

**See updated "Files to Modify" section for implementation details.**

---

### 3. DR Conflict Handling

**Question**: Should DR vault certificate creation have same conflict handling as Primary (retrieve existing operation on 409), or fail fast on conflict?

**Options**:
- **A**: Fail fast - conflict indicates configuration problem, admin should investigate
- **B**: Mirror Primary - handle conflict gracefully by retrieving existing operation
- **C**: Silent skip - if cert exists in DR, assume already replicated, continue

**Considerations**:
- How did cert get in DR if not through this app? (Manual creation? Previous failed run?)
- Is conflict in DR a normal scenario or error condition?

**Impact**: Code complexity in `FinalizeOrder()` method.

**Recommendation**: Start with Option B (mirror Primary) for consistency.

---

### 4. UI Validation for Unconfigured DR

**Question**: Should the UI show DR checkbox when `DrVaultBaseUrl` is not configured?

**Current approach**: Always show checkbox, backend silently skips if not configured

**Alternative approaches**:
- **Option A**: Add API endpoint `GET /api/configuration/dr-enabled` that returns boolean
  - Frontend calls on page load
  - Hide DR checkbox if DR not configured
  - Requires new API endpoint (extra work)

- **Option B**: Show checkbox with tooltip/help text: "DR vault must be configured in app settings"
  - Simple implementation
  - User feedback if DR not working

- **Option C**: Keep current approach (always show, silent skip)
  - Simplest
  - May confuse users if they select Yes but DR not configured

**Impact**: User experience and clarity.

**Recommendation**: Option C for MVP, can add validation later if needed.

---

### 5. Cross-Region Latency & Network Considerations

**Context**: DR KeyVault will ALWAYS be in a different Azure region than Primary vault (requirement confirmed).

**Question**: Are there any network or latency considerations for cross-region KeyVault access?

**Known facts**:
- ✅ Azure Managed Identity works across regions within same cloud environment (fully supported)
- ✅ Cross-region KeyVault access is standard DR pattern
- ⚠️ Cross-cloud scenarios (e.g., Primary in AzureCloud, DR in AzureUSGovernment) are OUT OF SCOPE

**Potential considerations**:
- Increased latency for DR write operations (acceptable for cert creation, not performance-critical)
- Network routing between Function App region and DR vault region
- KeyVault firewall rules: Both vaults must allow Function App's outbound IPs (if IP restrictions enabled)
- Service endpoints/private endpoints: Must be configured for Function App's region

**Impact**: Minimal - cross-region KeyVault access is standard Azure pattern.

**Recommendation**:
- Document that DR vault must be in different region, same cloud environment
- Add note in deployment guide about KeyVault firewall/network settings if applicable
- No code changes needed (DefaultAzureCredential handles cross-region automatically)

---

### 6. Certificate Comparison/Validation

**Question**: Should we validate that DR cert matches Primary cert after creation?

**Current approach**: Assume if DR creation succeeds, cert is identical (same policy, same CSR)

**Alternative**: After DR creation, compare:
- Thumbprint
- Expiry date
- Certificate policy
- Tags

**Considerations**:
- Extra API calls (read from DR vault)
- Increased latency
- Catches DR vault corruption/issues

**Impact**: Reliability vs. performance tradeoff.

**Recommendation**: Not needed for MVP, DR vault is passive backup.

---

### 7. Monitoring & Alerting

**Question**: Should we add specific monitoring/alerting for DR replication failures?

**Current approach**: Standard Application Insights logging via `logger.LogError()`

**Possible enhancements**:
- Custom metric: "DR replication success rate"
- Alert rule: "DR replication failed X times in Y minutes"
- Dashboard widget: "Certificates with DR replication enabled"

**Impact**: Operational visibility.

**Recommendation**: Use existing logging for MVP, add custom metrics in Phase 2.

---

## Implementation Order

Recommended sequence to minimize risk and enable incremental testing:

### Phase 1: Backend Infrastructure (No UI)
1. ✅ Create this planning document
2. Add `DrVaultBaseUrl` to `AcmebotOptions.cs`
3. Update `SharedActivity.cs`:
   - Add `TokenCredential` to constructor parameters
   - Add private fields for `_primaryClient` and `_drClient`
   - Initialize `_drClient` in constructor if configured
   - Replace all `certificateClient` references with `_primaryClient`
4. Test: Verify app still works with no DR configured (no regressions)

### Phase 2: Certificate Creation (Backend)
5. Add `UseDrReplication` property to `CertificatePolicyItem.cs`
6. Modify `SharedActivity.FinalizeOrder()`:
   - Add DR tag to metadata
   - Add DR vault replication logic
   - Add error handling and logging
7. Test: Manually POST to API with `useDrReplication: true`, verify cert created in both vaults

### Phase 3: UI Integration
8. Update `wwwroot/dashboard/index.html`:
   - Add DR checkbox
   - Add data property
   - Include in POST request
   - Reset on modal open
9. Test: Create cert via UI with checkbox, verify both vaults

### Phase 4: Renewal Flow
10. ✅ Research complete: Renewal uses `CertificateExtensions.ToCertificatePolicyItem()`
11. Update `CertificateExtensions.cs`:
    - Add `DrReplicatedKey` constant
    - Add `TryGetDrReplicated()` helper method
    - Update `ToCertificatePolicyItem()` to read `DrReplicated` tag and set `UseDrReplication`
    - Update `ToCertificateItem()` to exclude `DrReplicated` from custom tags
    - Update `ToCertificateMetadata()` to exclude `DrReplicated` from custom tags
12. Test: Create cert with DR, manually trigger renewal via API, verify renewal in both vaults

### Phase 5: Error Handling & Edge Cases
13. ✅ Research complete: No explicit rollback needed (see Open Question #1 - RESOLVED)
14. Add conflict handling for DR vault (optional - mirror Primary's 409 handling)
15. Test all error scenarios from checklist
16. Verify manual retry workflow: Fail cert creation → Fix issue → Dashboard Renew → Success

### Phase 6: Documentation & Deployment
17. Update README.md with DR feature documentation
18. Update IMPLEMENTATION_NOTES.md with DR implementation details
19. Create deployment guide for DR permissions setup
20. Deploy to test environment
21. Run full test suite
22. Deploy to production

---

## Success Criteria

Feature is complete when:

1. ✅ User can select DR checkbox in UI
2. ✅ Certificate created in Primary vault (always)
3. ✅ Certificate created in DR vault (when checkbox selected)
4. ✅ Both certs have `DrReplicated: "true"` tag
5. ✅ Both certs have identical content and tags
6. ✅ Certificate renewal respects DR setting
7. ✅ DR failure causes total operation failure (fail-fast)
8. ✅ Manual retry works after DR failure (conflict handler reuses Primary, DR succeeds)
9. ✅ All tests pass
10. ✅ Documentation updated
11. ✅ Deployed and verified in production

---

## Future Enhancements (Out of Scope)

Ideas for future iterations:

- **DR Vault Sync Tool**: Utility to replicate existing certs to DR vault
- **DR Validation Check**: Periodic job to verify DR certs match Primary
- **Multiple DR Vaults**: Support array of DR vaults (HA across regions)
- **Selective Rollback**: If DR fails, delete Primary cert and retry entire operation
- **Dashboard DR Status**: Show DR replication status per cert in UI
- **DR Vault Metrics**: Custom Application Insights metrics for DR replication
- **Retry with Backoff**: Retry DR creation separately without failing entire operation

---

## Notes

- All changes compatible with existing custom features (Certificate Tags, Application Gateway Integration)
- No breaking changes to existing API contracts
- DR vault is optional - app works normally without it
- DR vault is write-only from app perspective (no read operations)
- Primary vault remains source of truth for all certificate operations

---

**Document Created**: 2026-01-29
**Author**: Jake Farley with Claude Code
**Status**: Planning - Not Yet Implemented
