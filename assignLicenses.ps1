$ErrorActionPreference = 'Stop'  # set all errors to be terminating ones so they are handled in the try/catch blocks

$inputFileName = "user_list.csv"  # name of the input file
$inputPath = Join-Path $PSScriptRoot $inputFileName  # construct the input path string by taking the current directory and appending the input file name
$localLog = ".\O365_PS_log.txt"  # define a file name for a log
$higherSkuID = 'e578b273-6db4-4691-bba0-8d691f4da603'  # the SKU ID that will be assigned to only the specified list of users in the input file. See details for org licenses with "Get-MgSubscribedSku | Select -Property Sku*, ConsumedUnits -ExpandProperty PrepaidUnits | Format-List"
$basicSkuID = '94763226-9b3c-4e75-a931-5c89701abe66'  # the SKU ID that will be assigned to all other users
$oldA1PlusSkuID = '78e66a63-337a-4a9a-8959-41c6654dfb56'  # the SKU ID of an old license, will be removed from the higher user before license assignment

# SKUs that conflict with A3 and must be removed in the same call as the A3 add.
$conflictingSkuIDs = @(
    $oldA1PlusSkuID,
    $basicSkuID
)

$usageLocation = 'US'  # the usage location that will be set for any users who don't have one, since licenses cannot be assigned without a location

# Set to true in order to do a dry run, where the script will only log what it would do, but not actually make any changes to the users or licenses
$dryRun = $true

# Clear out log file from previous run
Clear-Content -Path $localLog

# Entra Credentials for our app
$entraAppClientID = $Env:MS_ENTRA_GRAPH_CLIENT_ID  # get the client ID from the environment variable
$entraAppTenantID = $Env:MS_ENTRA_GRAPH_TENANT_ID  # get the tenant ID from the environment variable
$entraAppCertThumbprint = $Env:MS_ENTRA_GRAPH_CERTIFICATE_THUMBPRINT  # get the app certificate thumbprint from the environement variable
Connect-MgGraph -ClientID $entraAppClientID -TenantID $entraAppTenantID -CertificateThumbprint $entraAppCertThumbprint -NoWelcome  # make the connection via MS Graph

$users = Get-Content -Path $InputPath  # read the input file and store the emails in users


# Retry helper - Graph throttles aggressively and newly-synced objects 404 briefly
function Invoke-GraphWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [string]$Context = 'Graph call',
        [int]$MaxAttempts = 4,
        [int]$BaseDelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        }
        catch {
            $msg = $_.Exception.Message

            # Transient: throttling, gateway errors, and objects not yet replicated.
            $isTransient = $msg -match 'throttl|too many requests|\b429\b|\b503\b|\b504\b|timed out|temporarily unavailable|ServiceUnavailable|Request_ResourceNotFound|does not exist or one of its queried reference-property'

            if ($attempt -ge $MaxAttempts -or -not $isTransient) { throw }

            $delay = [int]($BaseDelaySeconds * [math]::Pow(2, $attempt - 1))
            Write-Log WARN "Transient failure on $Context (attempt $attempt/$MaxAttempts), retrying in ${delay}s :: $msg"
            Start-Sleep -Seconds $delay
        }
    }
}

# Preflight: confirm our SKUs are active and have seats

$allSkus = Invoke-GraphWithRetry -Context 'Get-MgSubscribedSku' -Action { Get-MgSubscribedSku -All }  # get information about all SKUs in the tenant, including how many are available and how many are consumed

function Test-SkuUsable {
    param([string]$SkuId, [string]$Label, [int]$NeededSeats = 1)

    $sku = $allSkus | Where-Object SkuId -eq $SkuId
    if (-not $sku) {
        $message = "ERROR: $Label ($SkuId) is not present in this tenant."
        Write-Output $message
        $message | Out-File -FilePath $localLog -Append  # output to log
        return $false
    }
    $available = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
    if ($sku.CapabilityStatus -ne 'Enabled') {
        $message = "ERROR: $Label ($($sku.SkuPartNumber)) has CapabilityStatus '$($sku.CapabilityStatus)' - subscription is lapsed or suspended."
        Write-Output $message
        $message | Out-File -FilePath $localLog -Append  # output to log
        return $false
    }
    if ($available -lt $NeededSeats) {
        $message = "ERROR: $Label ($($sku.SkuPartNumber)) has $available seats available - not enough to proceed."
        Write-Output $message
        $message | Out-File -FilePath $localLog -Append  # output to log
        return $false
    }
    $message = "INFO: $Label ($($sku.SkuPartNumber)) is usable - $($sku.ConsumedUnits)/$($sku.PrepaidUnits.Enabled) used, $available available."
    Write-Output $message
    $message | Out-File -FilePath $localLog -Append  # output to log
    return $true
}

$higherOk = Test-SkuUsable -SkuId $higherSkuID -Label 'Higher SKU'
$basicOk  = Test-SkuUsable -SkuId $basicSkuID  -Label 'Basic SKU'

if (-not $basicOk) {
    Write-Log ERROR 'Basic SKU is unusable. Aborting.'
    Disconnect-MgGraph | Out-Null
    exit 1
}
if (-not $higherOk) {
    Write-Log WARN 'Higher SKU is unusable - A3 passes will be SKIPPED. Basic assignment will still run.'
}

# First, read all users from the directory only one time, everything else references this read
$message = "INFO: Reading all users from the directory, this can take a minute..."
Write-Output $message
$message | Out-File -FilePath $localLog -Append

$allUsers = Invoke-GraphWithRetry -Context 'Get-MgUser -All' -Action {
    Get-MgUser -All -Property Id,UserPrincipalName,DisplayName,UsageLocation,`
                              AccountEnabled,UserType,AssignedLicenses,`
                              LicenseAssignmentStates,OnPremisesSyncEnabled
}

$activeMembers = $allUsers | Where-Object {
    $_.UserType -eq 'Member' -and
    $_.AccountEnabled -eq $true -and
    $_.DisplayName -notin $excludedDisplayNames
}

# Set locations for any users who don't have one, since licenses cannot be assigned without a location
$needLocation = $activeMembers | Where-Object { [string]::IsNullOrWhiteSpace($_.UsageLocation) }
foreach ($user in $needLocation) {
    try {
        Invoke-GraphWithRetry -Context "Update-MgUser $($user.UserPrincipalName)" -Action {Update-MgUser -UserId $u.Id -UsageLocation $usageLocation}
        $message = "INFO: Set UsageLocation to 'US' for $($user.UserPrincipalName)"
        Write-Output $message
        $message | Out-File -FilePath $localLog -Append
    }
    catch {
        $message = "ERROR: Failed to set UsageLocation for $($user.UserPrincipalName): $($_.Exception.Message)"
        Write-Output $message
        $message | Out-File -FilePath $localLog -Append
    }
}
if ($needLocation.Count -gt 0) {
    $message = "INFO: Set UsageLocation for $($needLocation.Count) users. Sleeping for 120 seconds to allow replication before license assignment."
    Write-Output $message
    $message | Out-File -FilePath $localLog -Append
    Start-Sleep -Seconds 120
}

# First we want to go through the current licensed users for the higher SKU, and remove any that don't have a matching entry in our input file
if ($higherOk) {
    $currentHigher = $activeMembers | Where-Object {$_.AssignedLicenses.SkuId -contains $higherSkuID}
    $message = "INFO: Found $($currentHigher.Count) users currently assigned the higher SKU license."
    Write-Output $message
    $message | Out-File -FilePath $localLog -Append
    foreach ($user in $currentHigher) {
        $email = $user.UserPrincipalName
        if ($users -contains $email) {
            $message = "DBUG: $email has the higher license of SKU ID $higherSkuID and is still on the list of users who should, no changes needed"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append
        }
        else {
            $message = "INFO: $email has the higher license of SKU ID $higherSkuID but is not on the list of users who should, it will be removed"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append
            try {
                if ($dryRun) {
                    $message = "DRY RUN: Would remove higher SKU license for $email"
                    Write-Output $message
                    $message | Out-File -FilePath $localLog -Append
                }
                else {
                Invoke-GraphWithRetry -Context "Set-MgUserLicense Remove $($user.UserPrincipalName)" -Action {Set-MgUserLicense -UserId $user.Id -AddLicenses @{} -RemoveLicenses @($higherSkuID)}
                $successMessage = "INFO: License for $higherSkuID has been successfully removed from $email"
                Write-Output $successMessage
                $successMessage | Out-File -FilePath $localLog -Append
                }
            }
            catch {
                $message = "ERROR while trying to remove higher SKU license for $email: $($_.Exception.Message)"
                Write-Output $message
                $message | Out-File -FilePath $localLog -Append
            }
        }
    }
}

# Next we do the opposite, go through the list of users who should have higher tier licenses, add any that dont already have it
if ($higherOK) {
    foreach ($email in $users) {
        if ($currentHigher.UserPrincipalName -contains $email) {
            $message = "DBUG: $email already has a higher license of SKU ID $higherSkuID, no changes needed"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append
        }
        else {
            $toRemove = @($conflictingSkuIDs | Where-Object { $u.AssignedLicenses.SkuId -contains $_ })
            $message = "INFO: $email does not currently have a license for SKU ID $higherSkuID but is on the list of users who should, one will be assigned and $toRemove.Count conflicting licenses will be removed if present: $($toRemove -join ', ')"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append
            try {
                if ($dryRun) {
                    $message = "DRY RUN: Would assign higher SKU license for $email"
                    Write-Output $message
                    $message | Out-File -FilePath $localLog -Append
                }
                else {
                    Invoke-GraphWithRetry -Context "Assign higher license to $email" -Action {
                    Set-MgUserLicense -UserId $email `
                                      -AddLicenses @(@{SkuId = $higherSkuID}) `
                                      -RemoveLicenses $toRemove
                }
                    $successMessage = "INFO: License for $higherSkuID has been successfully assigned to $email"
                    Write-Output $successMessage
                    $successMessage | Out-File -FilePath $localLog -Append
                }
            }
            catch {
                $message = "ERROR while trying to assign higher SKU license for $email: $($_.Exception.Message)"
                Write-Output $message
                $message | Out-File -FilePath $localLog -Append
            }
        }
    }
}

# Do a strip of any users who still have the old A1 plus license, since it was retired back in 2025 but may still show up on some users.
$hasA1Plus = $activeMembers | Where-Object {$_.AssignedLicenses.SkuId -contains $oldA1PlusSkuID -and-not $users.Contains($_.UserPrincipalName)}
$message = "INFO: Found $($hasA1Plus.Count) users who still have the old A1 Plus license of SKU ID $oldA1PlusSkuID, it will be removed from them"
foreach ($u in $hasA1Plus) {
    $email = $u.UserPrincipalName

     # Would this leave them with no licenses at all?
        $otherLicenses = @($u.AssignedLicenses.SkuId | Where-Object { $_ -ne $oldA1PlusSkuID })
        $needsBasic    = ($otherLicenses.Count -eq 0)
        $addList = if ($needsBasic) { @(@{SkuId = $basicSkuID}) } else { @() }  # add the basic license if they have no other licenses, otherwise just remove the old A1 Plus license
        try {
            if ($DryRun) {
                $message = "DRY RUN: Would remove old A1 Plus license for $email and add basic license if needed ($needsBasic)"
                Write-Output $message
                $message | Out-File -FilePath $localLog -Append
            }
            else {
                Invoke-GraphWithRetry -Context "Retire old A1 Plus for $email" -Action {
                    Set-MgUserLicense -UserId $u.Id `
                                      -AddLicenses $addList `
                                      -RemoveLicenses @($oldA1PlusSkuID)
                }
                $successMessage = "INFO: License for $oldA1PlusSkuID has been successfully removed from $email"
                Write-Output $successMessage
                $successMessage | Out-File -FilePath $localLog -Append
            }
}

# Finally, go through all other unlicensed active users in the domain and try to give them the basic license
$unlicensed = $activeMembers | Where-Object {$_.AssignedLicenses.Count -eq 0}  # get active users with no assigned licenses
foreach ($u in $unlicensed) {
    $email = $u.UserPrincipalName
    if ($users.Contains($email)){
        $message = "DBUG: $email is unlicensed but is on the list of users who should have a higher license, so they should have already gotten a license in the previous pass"
        Write-Output $message
        $message | Out-File -FilePath $localLog -Append
        continue
    }
    try {
        if ($DryRun) {
            $message = "DRY RUN: Would assign basic license for $email"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append
        }
        else {
            Invoke-GraphWithRetry -Context "Assign basic license to $email" -Action {
                Set-MgUserLicense -UserId $u.Id `
                                  -AddLicenses @(@{SkuId = $basicSkuID}) `
                                  -RemoveLicenses @()
            }
            $successMessage = "INFO: License for $basicSkuID has been successfully assigned to $email"
            Write-Output $successMessage
            $successMessage | Out-File -FilePath $localLog -Append
        }
    }
}

Disconnect-MgGraph | Out-Null # disconnect from MS Graph