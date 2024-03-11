<#
.DESCRIPTION  
Script to get the Latest and the current API Versions of the Azure Resources that are deployed in GC Subscription.
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory=$true)]$pat,
    [Parameter(Mandatory=$true)]$outputFileCSV
    )

# Preparing the Variables.
$orgName = "<Org Name>"                         # Azure DevOps Org Name.
$orgUrl = "https://dev.azure.com/$orgName"   # Something like - https://dev.azure.com/AzureDevOps
$pat = "$PAT"                                  # This is required to read the Azure Repos.
$projectName = "<Project Name>"                 # Name of the Project where all the IaC (ARM/bicep) files/repos are present. 
$outputFolder = "D:\Agent\Repos"
$outputFile = "D:\Agent\Repos\output.txt"
$outputFileAPI = "D:\Agent\Repos\AzResourceAPI.txt"
$outputFileAPITmp = "D:\Agent\Repos\AzResourceAPITmp.txt"
$outputFileCSV = $outputFileCSV
# Create an array to hold the results for each resource type
$results = @()

# Cleaning the environment.
Remove-Item $outputFolder\* -Recurse -Force

# REST API to get the List of Repos under the provided AzDO Project.
$baseUrl = "$orgUrl/$projectName/_apis/git/repositories?api-version=6.1-preview.1"

$headers = @{
    Authorization = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")))"
    Accept        = "application/json"
}

# Get the list of all the Repos under the provided AzDO Project and store in the $repos variable.
$repos = (Invoke-RestMethod -Uri $baseUrl -Method Get -Headers $headers).value

# Clone and download all the Repos locally.
foreach ($repo in $repos) {
    $repoName = $repo.name
    #$repoUrl = $repo.remoteUrl
    $repoUrl = $repo.remoteUrl.Replace("https://$orgName", "https://$($PAT)")
    $repoFolder = Join-Path $outputFolder $repoName

    if (!(Test-Path $repoFolder)) {
        New-Item -ItemType Directory -Path $repoFolder | Out-Null
    }

    Write-Host "Downloading repository '$repoName' from '$repoUrl' to '$repoFolder'..."
    git clone $repoUrl $repoFolder
}

# Get all the files that contain deploy/template in their name & extract the type & apiVersion from each file's JSON content, 
# writes them to an output file, and remove duplicates.
Get-ChildItem -Path $outputFolder -Recurse -File | Where-Object {$_.Name -like "*deploy*" -or $_.Name -like "*template*"} | ForEach-Object {
    $jsonContent = Get-Content $_.FullName | ForEach-Object { $_ -replace '^\s*//' } | ConvertFrom-Json
    $jsonContent.resources | Select-Object -Property type, apiVersion | Out-File -FilePath $outputFile -Append
    Get-Content $outputFile | Select-Object -Unique | Out-File -FilePath $outputFileAPITmp
}
# Removing Whitespaces after the APIVersion.
Get-Content -Path $outputFileAPITmp | ForEach-Object { $_.TrimEnd() } | Out-File -FilePath $outputFileAPI

# Retrieve all resource types for the current subscription
$AllResourceTypes = Get-AzResource | Group-Object ResourceType | Select-Object -ExpandProperty Name

foreach ($ResourceType in $AllResourceTypes) {

    $provider, $azresourceType = $ResourceType -split '/', 2
    
    # Get the 3 Latest API Versions for each Resource Type. 
    $NameSpace = Get-AzResourceProvider -ProviderNamespace $provider
    $ApiVersions = ($NameSpace.ResourceTypes | Where-Object ResourceTypeName -eq $azresourceType).ApiVersions
    Write-Host "Latest 3 API Versions for $ResourceType are:"
    $ApiVersions | Select-Object -First 3
    $LatestApiVersion = $ApiVersions | Select-Object -First 3

    #Get the Current APIVersion from the $outputFileAPI file.
    $currentApiVersion = Get-Content $outputFileAPI | Select-String -Pattern "^($ResourceType)\s+(.+)$" | 
    ForEach-Object { $_.Matches.Groups[2].Value } | Select-Object -First 1
    Write-Host "The current apiVersion for $ResourceType resource type is $CurrentApiVersion"

    if ([string]::IsNullOrEmpty($CurrentApiVersion)) {
        $result = "Unable to get the current API Version"
    }
    elseif ($LatestApiVersion -contains $CurrentApiVersion) {
        $result = "Current Api version is one of the Latest API Versions"
    }
    else {
        $result = "The current API version is outdated"
    }
    Write-Output $result

    # Create a hashtable with the results for this resource type.
    $row = @{
        ResourceType = $ResourceType
        LatestApiVersion = $LatestApiVersion -join ","
        CurrentApiVersion = $currentApiVersion
        Status = $result
    }
    # Add the hashtable to the results array.
    $results += New-Object psobject -Property $row
    Write-Host "=============================================================="
}

# Export the results to a CSV file
$results | Sort-Object -Unique ResourceType | Export-Csv -Path $outputFileCSV -NoTypeInformation
