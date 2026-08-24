// Reproduces the "custom DNS blocked by NSG" scenario for an identity-based
// Linux .NET-isolated (v10) Elastic Premium Function App behind a VNet whose
// NSG denies all outbound except HTTPS (no port-53 / DNS allow).
//
// Every resource is tagged SecurityControl=Ignore. Tag the resource group the
// same way when you create it (see README).

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Short prefix used to derive resource names.')
param namePrefix string = 'dnsrepro'

@description('Suffix appended to resource names. Defaults to a hash of the resource group id; set explicitly (e.g. "11762") to reproduce fixed names.')
param resourceSuffix string = uniqueString(resourceGroup().id)

@description('Custom (unreachable / non-forwarding) DNS servers to force the failure, matching the customer.')
param customDnsServers array = [
  '172.28.16.100'
  '172.26.16.100'
]

@description('Common tags applied to every resource.')
param tags object = {
  SecurityControl: 'Ignore'
}

@description('Deploy the VNet + NSG. Set false to reuse an existing network (e.g. when a residual App Service Link locks the subnet).')
param deployNetwork bool = true

var suffix = resourceSuffix
var storageName = toLower('st${namePrefix}${suffix}')
var vnetName = 'vnet-${namePrefix}-${suffix}'
var nsgName = 'nsg-func-${namePrefix}-${suffix}'
var planName = 'plan-${namePrefix}-${suffix}'
var appName = 'func-${namePrefix}-${suffix}'
var subnetName = 'snet-func'

// Built-in role definition IDs
var blobDataOwnerRoleId = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueDataContributorRoleId = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = if (deployNetwork) {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'allow-func-to-vnet-out'
        properties: {
          priority: 300
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
          description: 'Allow Function App HTTPS to the VNET'
        }
      }
      {
        name: 'allow-func-to-storage-out'
        properties: {
          priority: 301
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Storage'
          destinationPortRange: '443'
          description: 'Allow Function App HTTPS to Azure Storage'
        }
      }
      {
        name: 'allow-func-to-internet-saas-out'
        properties: {
          priority: 304
          direction: 'Outbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRange: '443'
          description: 'Allow Function App HTTPS egress to public SaaS'
        }
      }
      {
        // The critical omission: no UDP/TCP 53 allow. DNS falls through to this deny.
        name: 'moduledefault-deny-all-out'
        properties: {
          priority: 4096
          direction: 'Outbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Default deny-all outbound'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = if (deployNetwork) {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.100.0.0/16'
      ]
    }
    dhcpOptions: {
      dnsServers: customDnsServers
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.100.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
          serviceEndpoints: [
            {
              service: 'Microsoft.Storage'
            }
          ]
          delegations: [
            {
              name: 'serverFarmDelegation'
              properties: {
                serviceName: 'Microsoft.Web/serverFarms'
              }
            }
          ]
        }
      }
    ]
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
  }
}

var subnetId = resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  sku: {
    tier: 'ElasticPremium'
    name: 'EP1'
  }
  kind: 'elastic'
  properties: {
    reserved: true // Linux
    maximumElasticWorkerCount: 3
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  dependsOn: deployNetwork ? [vnet] : []
  properties: {
    serverFarmId: plan.id
    reserved: true
    virtualNetworkSubnetId: subnetId
    siteConfig: {
      linuxFxVersion: 'DOTNET-ISOLATED|10.0'
      vnetRouteAllEnabled: true
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
        {
          // Identity-based storage: no connection string, resolution required.
          name: 'AzureWebJobsStorage__accountName'
          value: storage.name
        }
        {
          name: 'AzureWebJobsStorage__blobServiceUri'
          value: 'https://${storage.name}.blob.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__queueServiceUri'
          value: 'https://${storage.name}.queue.${environment().suffixes.storage}'
        }
        {
          name: 'AzureWebJobsStorage__tableServiceUri'
          value: 'https://${storage.name}.table.${environment().suffixes.storage}'
        }
        {
          name: 'WEBSITE_VNET_ROUTE_ALL'
          value: '1'
        }
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'true'
        }
      ]
    }
    httpsOnly: true
  }
}

resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, app.id, blobDataOwnerRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataOwnerRoleId)
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource queueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, app.id, queueDataContributorRoleId)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueDataContributorRoleId)
    principalId: app.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = app.name
output storageAccountName string = storage.name
output vnetName string = vnet.name
output nsgName string = nsg.name
output scmCommandUrl string = 'https://${app.name}.scm.azurewebsites.net/api/command'
