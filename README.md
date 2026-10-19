# Hub and spoke lab

A lab that deploys a hub-and-spoke network on Azure with Bicep: one hub, two spokes, an Azure Firewall in the hub, and a storage account reachable only through a private endpoint.

## Origin

This project is copied and modified from [Azure-Samples/azure-hub-spoke](https://github.com/Azure-Samples/azure-hub-spoke) (the `hub-spoke` folder), released under the Microsoft MIT license (see [LICENSE](LICENSE)).

Changes from the original:

- Removed Azure Bastion, the VPN gateway, the sample virtual machines and Log Analytics.
- Added a storage account (public access disabled), a private endpoint, a private DNS zone for blob, and a firewall rule that allows HTTPS to the private endpoint.
- Split `main.bicep` into three modules: hub, spoke one and spoke two.
- Moved all IP ranges into `main.bicepparam`.
- Added GitHub Actions to deploy the infrastructure and push content to blob storage.

## Architecture

| Component | Description |
| :--- | :--- |
| Hub | VNet with `AzureFirewallSubnet`, Azure Firewall (Basic) and its firewall policy, a DDoS protection plan, and a route table that sends `0.0.0.0/0` to the firewall. |
| Spoke one | VNet with `snet-resources` and `snet-privatelinkendpoints`. Hosts the storage account (public access disabled), a blob private endpoint, the `worklogs` container, and the `privatelink.blob.*` private DNS zone. |
| Spoke two | VNet with `snet-resources`, where the agent/runner lives. Linked to the private DNS zone so the storage name resolves to the private IP. |
| Peering | The hub is peered both ways with each spoke. Traffic between the spokes goes through the firewall. |

The firewall policy has two rules: allow DNS (UDP 53), and allow HTTPS (TCP 443) from the spoke two subnet to the spoke one private endpoint subnet.

## Repository layout

```
bicep/
  main.bicep          # parameters, shared NSGs, module calls
  main.bicepparam     # values for every IP range
  modules/
    hub.bicep
    spoke-one.bicep
    spoke-two.bicep
.github/workflows/
  infra.yml           # what-if on PRs, deploy on push to main or manual run
  push-to-blob.yml    # manual only, uploads content to blob storage
```

## Parameters

Default values live in [bicep/main.bicepparam](bicep/main.bicepparam).

| Parameter | Description | Value |
| :--- | :--- | :--- |
| `location` | Deployment region. Must support availability zones. | `resourceGroup().location` |
| `hubAddressPrefix` | Address space of the hub VNet. | `10.0.0.0/22` |
| `hubFirewallSubnetPrefix` | `AzureFirewallSubnet` (/26 or larger). | `10.0.3.0/26` |
| `spokeOneAddressPrefix` | Address space of spoke one. | `10.100.0.0/22` |
| `spokeOneResourcesSubnetPrefix` | `snet-resources` in spoke one. | `10.100.0.0/24` |
| `spokeOnePrivateLinkSubnetPrefix` | `snet-privatelinkendpoints` in spoke one. | `10.100.1.0/26` |
| `spokeTwoAddressPrefix` | Address space of spoke two. | `10.200.0.0/22` |
| `spokeTwoResourcesSubnetPrefix` | `snet-resources` in spoke two (agent). | `10.200.0.0/24` |

## Deploy

```bash
LOCATION=eastus2
RESOURCEGROUP_NAME=rg-hub-spoke-${LOCATION}

az group create --name ${RESOURCEGROUP_NAME} --location ${LOCATION}

az deployment group create \
    --resource-group ${RESOURCEGROUP_NAME} \
    --template-file bicep/main.bicep \
    --parameters bicep/main.bicepparam
```

If the resource group's region does not support availability zones, add `location=<region with zones>` to `--parameters`.

## GitHub Actions

Configure these in the repository settings:

- Secrets: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` (OIDC login).
- Variables: `AZURE_RESOURCE_GROUP`, `AZURE_STORAGE_ACCOUNT`.

`push-to-blob.yml` runs on a self-hosted runner labeled `spoke-two`, because the storage account is reachable only through the private endpoint.

## Clean up

```bash
az group delete --name ${RESOURCEGROUP_NAME} --yes
```
