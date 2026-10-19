targetScope = 'resourceGroup'

@description('The location of this regional hub. All resources, including spoke resources, will be deployed to this region. This region must support availability zones.')
@minLength(6)
param location string = resourceGroup().location

@description('Address space of the hub VNet.')
param hubAddressPrefix string

@description('Address prefix of the AzureFirewallSubnet in the hub (must be /26 or larger).')
param hubFirewallSubnetPrefix string

@description('Address space of spoke one VNet.')
param spokeOneAddressPrefix string

@description('Address prefix of snet-resources in spoke one.')
param spokeOneResourcesSubnetPrefix string

@description('Address prefix of snet-privatelinkendpoints in spoke one.')
param spokeOnePrivateLinkSubnetPrefix string

@description('Address space of spoke two VNet.')
param spokeTwoAddressPrefix string

@description('Address prefix of snet-resources in spoke two (where the agent lives).')
param spokeTwoResourcesSubnetPrefix string

@description('Address prefix of snet-privatelinkendpoints in spoke two.')
param spokeTwoPrivateLinkSubnetPrefix string

resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2021-05-01' = {
  name: 'vnet-${location}-ddos'
  location: location
}

@description('The regional hub network.')
resource vnetHub 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-${location}-hub'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'AzureFirewallSubnet'
        properties: {
          addressPrefix: hubFirewallSubnetPrefix
          defaultOutboundAccess: false
        }
      }
    ]
    enableDdosProtection: true
    ddosProtectionPlan: {
      id: ddosProtectionPlan.id
    }
  }

  resource azureFirewallSubnet 'subnets' existing = {
    name: 'AzureFirewallSubnet'
  }

  resource peerToSpokeOne 'virtualNetworkPeerings@2024-07-01' = {
    name: 'to_${vnetSpokeOne.name}'
    dependsOn: [
      vnetSpokeOne::peerToHub // This artificially waits until the spoke peers with the hub first to control order of operations.
    ]
    properties: {
      allowForwardedTraffic: true //change
      allowGatewayTransit: false
      allowVirtualNetworkAccess: true
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: vnetSpokeOne.id
      }
    }
  }

  resource peerToSpokeTwo 'virtualNetworkPeerings@2024-07-01' = {
    name: 'to_${vnetSpokeTwo.name}'
    dependsOn: [
      vnetSpokeTwo::peerToHub // This artificially waits until the spoke peers with the hub first to control order of operations.
    ]
    properties: {
      allowForwardedTraffic: true //change
      allowGatewayTransit: false
      allowVirtualNetworkAccess: true
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: vnetSpokeTwo.id
      }
    }
  }
}

var numFirewallIpAddressesToAssign = 1
resource pipsAzureFirewall 'Microsoft.Network/publicIPAddresses@2024-07-01' = [
  for i in range(0, numFirewallIpAddressesToAssign): {
    name: 'pip-fw-${location}-${padLeft(i, 2, '0')}' // like pip-fw-southeastasia-00, -01, -02
    location: location
    sku: {
      name: 'Standard'
    }
    zones: [
      '1'
    ]
    properties: {
      publicIPAllocationMethod: 'Static'
      idleTimeoutInMinutes: 4
      publicIPAddressVersion: 'IPv4'
    }
  }
]

@description('Azure Firewall Policy')
resource fwPolicy 'Microsoft.Network/firewallPolicies@2024-07-01' = {
  name: 'fw-policies-${location}'
  location: location
  properties: {
    sku: {
      tier: 'Basic'
    }
    threatIntelMode: 'Deny' // filter the malware ip
    threatIntelWhitelist: {
      fqdns: [] //domain
      ipAddresses: [] //ip
    }
    intrusionDetection: null // Only valid on Premium tier sku // IDPS = Intrusion Detection and Prevention System = IDPS nhìn vào nội dung bên trong gói tin để phát hiện mẫu tấn công, kể cả khi địa chỉ và port trông bình thường.
    dnsSettings: {
      servers: []
      enableProxy: true
    }
  }

  resource defaultNetworkRuleCollectionGroup 'ruleCollectionGroups@2024-07-01' = {
    name: 'DefaultNetworkRuleCollectionGroup'
    properties: {
      priority: 200
      ruleCollections: [
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'org-wide-allowed'
          priority: 100
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'DNS'
              description: 'Allow DNS outbound (for simplicity, adjust as needed)' // ban than firewall cung can dươc bat port 53 de queries dns
              ipProtocols: [
                'UDP'
              ]
              sourceAddresses: [
                '*'
              ]
              sourceIpGroups: []
              destinationAddresses: [
                '*'
              ]
              destinationIpGroups: []
              destinationFqdns: []
              destinationPorts: [
                '53'
              ]
            }
            {
              ruleType: 'NetworkRule'
              name: 'AllowHttpsToPE'
              ipProtocols: ['TCP']
              sourceAddresses: [spokeTwoResourcesSubnetPrefix] // agent ở spoke-two
              destinationAddresses: [spokeOnePrivateLinkSubnetPrefix] // dải PE ở spoke-one
              destinationPorts: ['443']
              sourceIpGroups: []
              destinationIpGroups: []
              destinationFqdns: []
            }
          ]
        }
      ]
    }
  }

}

@description('This is the regional Azure Firewall that all regional spoke networks can egress through.')
resource fwHub 'Microsoft.Network/azureFirewalls@2024-07-01' = {
  name: 'fw-${location}'
  location: location
  zones: [
    '1'
  ]
  dependsOn: [
    fwPolicy::defaultNetworkRuleCollectionGroup
  ]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: 'Basic'
    }
    firewallPolicy: {
      id: fwPolicy.id
    }
    ipConfigurations: [
      for i in range(0, numFirewallIpAddressesToAssign): {
        name: pipsAzureFirewall[i].name
        properties: {
          subnet: (0 == i)
            ? {
                id: vnetHub::azureFirewallSubnet.id
              }
            : null
          publicIPAddress: {
            id: pipsAzureFirewall[i].id
          }
        }
      }
    ]
  }
}

@description('Next hop to the regional hub\'s Azure Firewall')
resource routeNextHopToFirewall 'Microsoft.Network/routeTables@2024-07-01' = {
  name: 'route-to-${location}-hub-fw'
  location: location
  properties: {
    routes: [
      {
        name: 'r-nexthop-to-fw'
        properties: {
          nextHopType: 'VirtualAppliance'
          addressPrefix: '0.0.0.0/0'
          nextHopIpAddress: fwHub.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

@description('NSG on the resource subnet (just using a common one for all as an example, but usually would be based on the specific needs of the spoke).')
resource nsgResourcesSubnet 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-spoke-resources'
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyAllInBound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
    ]
  }
}

@description('NSG on the Private Link subnet (just using a common one for all as an example, but usually would be based on the specific needs of the spoke).')
resource nsgPrivateLinkEndpointsSubnet 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-spoke-privatelinkendpoints'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowAll443InFromVnet'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          destinationPortRange: '443'
          destinationAddressPrefix: 'VirtualNetwork'
          access: 'Allow'
          priority: 100
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Inbound'
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          protocol: '*'
          sourcePortRange: '*'
          sourceAddressPrefix: '*'
          destinationPortRange: '*'
          destinationAddressPrefix: '*'
          access: 'Deny'
          priority: 1000
          direction: 'Outbound'
        }
      }
    ]
  }
}

resource vnetSpokeOne 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-${location}-spoke-one'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        spokeOneAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-resources'
        properties: {
          addressPrefix: spokeOneResourcesSubnetPrefix
          networkSecurityGroup: {
            id: nsgResourcesSubnet.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
          routeTable: {
            id: routeNextHopToFirewall.id
          }
        }
      }
      {
        name: 'snet-privatelinkendpoints'
        properties: {
          addressPrefix: spokeOnePrivateLinkSubnetPrefix
          networkSecurityGroup: {
            id: nsgPrivateLinkEndpointsSubnet.id
          }
          privateEndpointNetworkPolicies: 'Enabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
          routeTable: {
            id: routeNextHopToFirewall.id
          }
        }
      }
    ]
    enableDdosProtection: true
    ddosProtectionPlan: {
      id: ddosProtectionPlan.id
    }
  }

  resource snetResources 'subnets' existing = {
    name: 'snet-resources'
  }

  resource snetPrivateLinkEndpoints 'subnets' existing = {
    name: 'snet-privatelinkendpoints'
  }

  resource peerToHub 'virtualNetworkPeerings@2024-07-01' = {
    name: 'to_${vnetHub.name}'
    properties: {
      allowForwardedTraffic: true
      allowGatewayTransit: false
      allowVirtualNetworkAccess: true
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: vnetHub.id
      }
    }
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: 'stworklog${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    allowBlobPublicAccess: false
  }
}

resource pe 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: 'pe-storage-blob'
  location: location
  properties: {
    subnet: { id: vnetSpokeOne::snetPrivateLinkEndpoints.id }
    privateLinkServiceConnections: [
      {
        name: 'blob'
        properties: {
          privateLinkServiceId: storage.id
          groupIds: ['blob']
        }
      }
    ]
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: storage
  name: 'default'
}
resource worklogContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = {
  parent: blobService
  name: 'worklogs'
}

resource blobDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

resource blobDnsLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: blobDnsZone
  name: 'link-to-spoke-two'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnetSpokeTwo.id }
    registrationEnabled: false
  }
}

resource peDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: pe
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob'
        properties: { privateDnsZoneId: blobDnsZone.id }
      }
    ]
  }
}

resource vnetSpokeTwo 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-${location}-spoke-two'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        spokeTwoAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-resources'
        properties: {
          addressPrefix: spokeTwoResourcesSubnetPrefix
          networkSecurityGroup: {
            id: nsgResourcesSubnet.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Disabled'
          defaultOutboundAccess: false
          routeTable: {
            id: routeNextHopToFirewall.id
          }
        }
      }
    ]
    enableDdosProtection: true
    ddosProtectionPlan: {
      id: ddosProtectionPlan.id
    }
  }

  resource snetResources 'subnets' existing = {
    name: 'snet-resources'
  }

  resource peerToHub 'virtualNetworkPeerings@2024-07-01' = {
    name: 'to_${vnetHub.name}'
    properties: {
      allowForwardedTraffic: false
      allowGatewayTransit: false
      allowVirtualNetworkAccess: true
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: vnetHub.id
      }
    }
  }
}
