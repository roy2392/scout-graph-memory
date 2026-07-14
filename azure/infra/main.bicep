// Reference IaC for Phase 1 (the runnable path is azure/deploy.sh, which also
// builds the image with ACR Tasks and patches the job volume mount). This Bicep
// provisions the same core resources; deploy the image + job-volume mount after.
//
//   az group create -n rg-scout-graph-memory -l centralus
//   az deployment group create -g rg-scout-graph-memory -f azure/infra/main.bicep

@description('Azure region')
param location string = resourceGroup().location

@description('Base name for resources')
param baseName string = 'scoutmem'

@description('File share name')
param shareName string = 'memory'

var suffix = uniqueString(resourceGroup().id)
var storageName = toLower('st${baseName}${substring(suffix, 0, 6)}')
var acrName = toLower('acr${baseName}${substring(suffix, 0, 6)}')
var lawName = 'law-${baseName}'
var envName = 'cae-${baseName}'

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource share 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: shareName
  properties: {
    shareQuota: 5
  }
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: acrName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true
  }
}

resource env 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: envName
  location: location
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: law.properties.customerId
        sharedKey: law.listKeys().primarySharedKey
      }
    }
  }
}

resource envStorage 'Microsoft.App/managedEnvironments/storages@2024-03-01' = {
  parent: env
  name: 'memoryshare'
  properties: {
    azureFile: {
      accountName: storage.name
      accountKey: storage.listKeys().keys[0].value
      shareName: shareName
      accessMode: 'ReadWrite'
    }
  }
}

output storageAccount string = storage.name
output acrLoginServer string = acr.properties.loginServer
output environmentName string = env.name
output envStorageName string = envStorage.name
