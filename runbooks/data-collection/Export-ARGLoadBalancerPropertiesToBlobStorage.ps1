param(
    [Parameter(Mandatory = $false)]
    [string] $TargetSubscription = $null,

    [Parameter(Mandatory = $false)]
    [string] $externalCloudEnvironment = "",

    [Parameter(Mandatory = $false)]
    [string] $externalTenantId = "",

    [Parameter(Mandatory = $false)]
    [string] $externalCredentialName = ""
)

$ErrorActionPreference = "Stop"

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name  "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

# get ARG exports sink (storage account) details
$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_ARGLoadBalancerContainer" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($storageAccountSinkContainer))
{
    $storageAccountSinkContainer = "arglbexports"
}

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    $externalCredential = Get-AutomationPSCredential -Name $externalCredentialName
}

$ARGPageSize = 1000

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity -EnvironmentName $cloudEnvironment
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

$cloudSuffix = ""

if (-not([string]::IsNullOrEmpty($externalCredentialName)))
{
    Connect-AzAccount -ServicePrincipal -EnvironmentName $externalCloudEnvironment -Tenant $externalTenantId -Credential $externalCredential 
    $cloudSuffix = $externalCloudEnvironment.ToLower() + "-"
    $cloudEnvironment = $externalCloudEnvironment   
}

$tenantId = (Get-AzContext).Tenant.Id

$allLBs = @()

Write-Output "Getting subscriptions target $TargetSubscription"
if (-not([string]::IsNullOrEmpty($TargetSubscription)))
{
    $subscriptions = $TargetSubscription
    $subscriptionSuffix = $TargetSubscription
}
else
{
    $subscriptions = Get-AzSubscription | Where-Object { $_.State -eq "Enabled" } | ForEach-Object { "$($_.Id)"}
    $subscriptionSuffix = $cloudSuffix + "all-" + $tenantId
}

$LBsTotal = @()
$resultsSoFar = 0

Write-Output "Querying for Load Balancer properties"

$argQuery = @"
resources
| where type =~ 'Microsoft.Network/loadBalancers'
| extend lbType = iif(properties.frontendIPConfigurations contains 'publicIPAddress', 'Public', iif(properties.frontendIPConfigurations contains 'privateIPAddress', 'Internal', 'Unknown'))
| extend lbRulesCount = array_length(properties.loadBalancingRules)
| extend frontendIPsCount = array_length(properties.frontendIPConfigurations)
| extend inboundNatRulesCount = array_length(properties.inboundNatRules)
| extend outboundRulesCount = array_length(properties.outboundRules)
| extend inboundNatPoolsCount = array_length(properties.inboundNatPools)
| extend backendPoolsCount = array_length(properties.backendAddressPools)
| extend probesCount = array_length(properties.probes)
| project id, name, resourceGroup, subscriptionId, tenantId, location, skuName = sku.name, skuTier = sku.tier, lbType, lbRulesCount, frontendIPsCount, inboundNatRulesCount, outboundRulesCount, inboundNatPoolsCount, backendPoolsCount, probesCount, tags
| join kind=leftouter (
	resources
	| where type =~ 'Microsoft.Network/loadBalancers'
	| mvexpand backendPools = properties.backendAddressPools
	| extend backendIPCount = array_length(backendPools.properties.backendIPConfigurations)
	| summarize backendIPCount = sum(backendIPCount) by id
) on id
| project-away id1
| order by id asc
"@

do
{
    if ($resultsSoFar -eq 0)
    {
        $LBs = Search-AzGraph -Query $argQuery -First $ARGPageSize -Subscription $subscriptions
    }
    else
    {
        $LBs = Search-AzGraph -Query $argQuery -First $ARGPageSize -Skip $resultsSoFar -Subscription $subscriptions
    }
    if ($LBs -and $LBs.GetType().Name -eq "PSResourceGraphResponse")
    {
        $LBs = $LBs.Data
    }
    $resultsCount = $LBs.Count
    $resultsSoFar += $resultsCount
    $LBsTotal += $LBs

} while ($resultsCount -eq $ARGPageSize)

Write-Output "Found $($LBsTotal.Count) Load Balancer entries"

<#
    Building CSV entries 
#>

$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")
$statusDate = $datetime.ToString("yyyy-MM-dd")

foreach ($lb in $LBsTotal)
{
    $logentry = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $cloudEnvironment
        TenantGuid = $lb.tenantId
        SubscriptionGuid = $lb.subscriptionId
        ResourceGroupName = $lb.resourceGroup.ToLower()
        InstanceName = $lb.name.ToLower()
        InstanceId = $lb.id.ToLower()
        SkuName = $lb.skuName
        SkuTier = $lb.skuTier
        Location = $lb.location
        LbType = $lb.lbType
        LbRulesCount = $lb.lbRulesCount
        InboundNatRulesCount = $lb.inboundNatRulesCount
        OutboundRulesCount = $lb.outboundRulesCount
        FrontendIPsCount = $lb.frontendIPsCount
        BackendIPCount = $lb.backendIPCount
        InboundNatPoolsCount = $lb.inboundNatPoolsCount
        BackendPoolsCount = $lb.backendPoolsCount
        ProbesCount = $lb.probesCount
        StatusDate = $statusDate
        Tags = $lb.tags
    }
    
    $allLBs += $logentry
}

<#
    Actually exporting CSV to Azure Storage
#>

$today = $datetime.ToString("yyyyMMdd")
$csvExportPath = "$today-lbs-$subscriptionSuffix.csv"

$allLBs | Export-Csv -Path $csvExportPath -NoTypeInformation

$csvBlobName = $csvExportPath

$csvProperties = @{"ContentType" = "text/csv"};

Set-AzStorageBlobContent -File $csvExportPath -Container $storageAccountSinkContainer -Properties $csvProperties -Blob $csvBlobName -Context $sa.Context -Force