using './main.bicep'

// Hub
param hubAddressPrefix = '10.0.0.0/22'
param hubFirewallSubnetPrefix = '10.0.3.0/26'

// Spoke one (storage + private endpoint)
param spokeOneAddressPrefix = '10.100.0.0/22'
param spokeOneResourcesSubnetPrefix = '10.100.0.0/24'
param spokeOnePrivateLinkSubnetPrefix = '10.100.1.0/26'

// Spoke two (agent)
param spokeTwoAddressPrefix = '10.200.0.0/22'
param spokeTwoResourcesSubnetPrefix = '10.200.0.0/24'
param spokeTwoPrivateLinkSubnetPrefix = '10.200.1.0/26'
