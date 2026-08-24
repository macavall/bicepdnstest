# Custom DNS Blocked by NSG — Function App Repro

Deploys an **identity-based, Linux .NET-isolated (v10) Elastic Premium Function App**
integrated into a VNet whose NSG **denies all outbound except HTTPS** and provides
**custom DNS servers with no port-53 allow rule**. This reproduces the failure where
the Functions host cannot resolve its storage account, producing
`SocketException (11001): No such host is known`, `AzureWebJobsStorage: Unhealthy`,
and 100-second `SyncTriggers` timeouts.

All resources — and the resource group — are tagged `SecurityControl=Ignore`.

## Files

| File | Purpose |
|------|---------|
| `main.bicep` | The environment definition |
| `test-dns.ps1` | Runs DNS/storage resolution checks *inside* the deployed app via Kudu |

## What gets deployed

- Storage account (identity-based; no connection string)
- VNet `10.100.0.0/16` with **custom DNS `172.28.16.100`, `172.26.16.100`**
- Subnet `10.100.1.0/24` delegated to `Microsoft.Web/serverFarms`, with an NSG
- NSG outbound rules: allow TCP 443 to VirtualNetwork / Storage / Internet, then
  **deny-all at priority 4096** (no UDP/TCP 53 rule — this is the injected fault)
- Elastic Premium (EP1) Linux plan
- Function App `DOTNET-ISOLATED|10.0`, system-assigned identity, `WEBSITE_VNET_ROUTE_ALL=1`
- Role assignments: Storage Blob Data Owner + Storage Queue Data Contributor for the app identity

## Prerequisites

- Azure CLI (with the `bicep` extension) **or** Azure PowerShell (`Az` module)
- Contributor + User Access Administrator (the template creates role assignments)

---

## Deploy with Azure CLI

```bash
RG=rg-dnsrepro-bicep
LOCATION=eastus

# Resource group MUST also carry the tag
az group create -n $RG -l $LOCATION --tags SecurityControl=Ignore

az deployment group create \
  --resource-group $RG \
  --template-file main.bicep
```

Optional — override the DNS servers or name prefix:

```bash
az deployment group create -g $RG --template-file main.bicep \
  --parameters namePrefix=dnsrepro customDnsServers='["172.28.16.100","172.26.16.100"]'
```

## Deploy with Azure PowerShell

```powershell
$RG = "rg-dnsrepro-bicep"
$Location = "eastus"

# Resource group MUST also carry the tag
New-AzResourceGroup -Name $RG -Location $Location -Tag @{ SecurityControl = "Ignore" }

New-AzResourceGroupDeployment `
  -ResourceGroupName $RG `
  -TemplateFile .\main.bicep
```

---

## Verify the repro (DNS is blocked)

Grab the `functionAppName` and `storageAccountName` from the deployment outputs, then:

```powershell
.\test-dns.ps1 -App <functionAppName> -Stg <storageAccountName>
```

Expected output (failure reproduced):

```
/etc/resolv.conf  -> nameservers 172.28.16.100, 172.26.16.100
getent hosts <stg>.blob.core.windows.net -> (empty)  EXIT: 2   # DNS failed
curl https://<stg>.blob.core.windows.net/ -> http=000  rc=3      # could not resolve
```

## Apply the fix and re-verify

Add an outbound rule allowing DNS (UDP/TCP 53) to a **reachable, forwarding** DNS
server, at a priority below the 4096 deny-all. Use Azure DNS `168.63.129.16` (which
resolves both public storage names and Azure-internal platform names):

```bash
az network nsg rule create -g $RG \
  --nsg-name <nsgName> \
  --name allow-func-to-dns-out \
  --direction Outbound --access Allow --priority 303 --protocol "*" \
  --source-address-prefixes "*" --source-port-ranges "*" \
  --destination-address-prefixes 168.63.129.16 --destination-port-ranges 53

az network vnet update -g $RG -n <vnetName> --dns-servers 168.63.129.16
az functionapp restart -g $RG -n <functionAppName>
```

> Note: a custom DNS server must **forward to Azure DNS (168.63.129.16)**. Pointing
> the VNet at a pure public resolver (e.g. 8.8.8.8) breaks platform startup because
> Azure-internal names won't resolve.

Re-run `test-dns.ps1` — `getent` should now return the storage IP and `curl` a real
HTTP status.

## Cleanup

```bash
az group delete -n rg-dnsrepro-bicep --yes --no-wait
```
