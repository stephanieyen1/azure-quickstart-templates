﻿param(
    $BuildSourcesDirectory = "$ENV:BUILD_SOURCESDIRECTORY",
    $StorageAccountResourceGroupName = "azure-quickstarts-service-storage",
    $StorageAccountName = "azurequickstartsservice",
    $TableName = "QuickStartsMetadataService",
    [Parameter(mandatory=$true)]$StorageAccountKey, 
    $ResultDeploymentLastTestDateParameter = "$ENV:RESULT_DEPLOYMENT_LAST_TEST_DATE_PARAMETER", # sort based on the cloud we're testing FF or Public
    $ResultDeploymentParameter = "$ENV:RESULT_DEPLOYMENT_PARAMETER", #also cloud specific
    $PurgeOldRows = $true
)
<#

Get all metadata files in the repo
Get entire table since is has to be sorted client side

For each file in the repo, check to make sure it's in the table
- if not add it with the date found in metadata.json

sort the table by date

Get the oldest LastTestDate, i.e. the sample that hasn't had a test in the longest time

If that metadata file doesn't exist, remove the table row

Else set the sample folder to run the test

#>

# Get the storage table that contains the "status" for the deployment/test results
$ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey -Environment AzureCloud
$cloudTable = (Get-AzStorageTable –Name $tableName –Context $ctx).CloudTable
$t = Get-AzTableRow -table $cloudTable

# Get all the samples
$ArtifactFilePaths = Get-ChildItem $BuildSourcesDirectory\metadata.json -Recurse -File | ForEach-Object -Process { $_.FullName }

# if this is empty, then everything would be removed from the table which is probably not the intent
if($ArtifactFilePaths.Count -eq 0){
    Write-Error "No metadata.json files found in $BuildSourcesDirectory"
    throw
}

#For each sample, make sure it's in the table before we check for the oldest
Write-Host "Checking table to see if this is a new sample (does the row exist?)"
foreach ($SourcePath in $ArtifactFilePaths) {
    
    #write-host $SourcePath

    if ($SourcePath -like "*\test\*") {
        Write-host "Skipping..."
        continue
    }

    $MetadataJson = Get-Content $SourcePath -Raw | ConvertFrom-Json

    # Get the sample's path off of the root, replace any path chars with "@" since the rowkey for table storage does not allow / or \ (among other things)
    $RowKey = (Split-Path $SourcePath -Parent).Replace("$(Resolve-Path $BuildSourcesDirectory)\", "").Replace("\", "@").Replace("/", "@")

    $r = $t | Where-Object { $_.RowKey -eq $RowKey }

    # if the row isn't found in the table, it could be a new sample, add it with the data found in metadata.json
    If ($r -eq $null) {

        Write-Host "Adding: $Rowkey"
        Add-AzTableRow -table $cloudTable `
            -partitionKey $MetadataJson.type `
            -rowKey $RowKey `
            -property @{
                "$ResultDeploymentParameter" = $false; `
                "PublicLastTestDate"     = "$($MetadataJson.dateUpdated)"; `
                "FairfaxLastTestDate"    = "$($MetadataJson.dateUpdated)"; 
        }
    }
}

#Get the updated table
$t = Get-AzTableRow -table $cloudTable

# for each row in the table - purge those that don't exist in the samples folder anymore
# note that if this build sources directory is wrong this will remove every row in the table (which would be bad)
if ($PurgeOldRows) {
    Write-Host "Purging Old Rows..."
    foreach ($r in $t) {

        $PathToSample = ("$BuildSourcesDirectory\$($r.RowKey)\metadata.json").Replace("@", "\")
        $MetadataJson = Get-Content $PathToSample -Raw | ConvertFrom-Json

        #If the sample isn't found in the repo or the Type has changed (and it's not null) then we want to remove the record
        If (!(Test-Path -Path $PathToSample)) {
            
            Write-Host "Sample Not Found - removing... $PathToSample"
            $r | Remove-AzTableRow -Table $cloudTable

        } elseif(($r.PartitionKey -ne $MetadataJson.type -and ![string]::IsNullOrWhiteSpace($MetadataJson.type))){
            
            #if the type has changed, update the type - this will create a new row since we use the partition key we so need to delete the old row
            Write-Host "Metadata type has changed from `'$($r.PartitionKey)`' to `'$($MetadataJson.type)`'"
            $oldRowKey = $r.RowKey
            $oldPartitionKey = $r.PartitionKey
            $r.PartitionKey = $MetadataJson.Type
            $r | Update-AzTableRow -table $cloudTable
            Get-AzTableRow -table $cloudTable -PartitionKey $oldPartitionKey -RowKey $oldRowKey | Remove-AzTableRow -Table $cloudTable 
            
        }
    }
}

$t = Get-AzTableRow -table $cloudTable | Sort-Object -Property $ResultDeploymentLastTestDateParameter # sort based on the last test date for the could being tested
$t | ft

# Write the pipeline variable
$FolderString = "$BuildSourcesDirectory\$($t[0].RowKey)"
Write-Output "Using sample folder: $FolderString"
Write-Host "##vso[task.setvariable variable=sample.folder]$FolderString"

# Not sure we need this in the scheduled build but here it is:

$sampleName = $FolderString.Replace("$ENV:BUILD_SOURCESDIRECTORY\", "")
Write-Output "Using sample name: $sampleName"
Write-Host "##vso[task.setvariable variable=sample.name]$sampleName"