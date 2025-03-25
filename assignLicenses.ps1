$ErrorActionPreference = 'Stop'  # set all errors to be terminating ones so they are handled in the try/catch blocks

$inputFileName = "user_list.csv"  # name of the input file
$inputPath = Join-Path $PSScriptRoot $inputFileName  # construct the input path string by taking the current directory and appending the input file name
$localLog = ".\O365_PS_log.txt"  # define a file name for a log
$higherSkuID = 'e578b273-6db4-4691-bba0-8d691f4da603'  # the SKU ID that will be assigned to only the specified list of users in the input file. See details for org licenses with "Get-MgSubscribedSku | Select -Property Sku*, ConsumedUnits -ExpandProperty PrepaidUnits | Format-List"
$basicSkuID = '94763226-9b3c-4e75-a931-5c89701abe66'  # the SKU ID that will be assigned to all other users
$oldSkuID = '78e66a63-337a-4a9a-8959-41c6654dfb56'  # the SKU ID of an old license, will be removed from the higher user before license assignment

# Clear out log file from previous run
Clear-Content -Path $localLog

# Entra Credentials for our app
$entraAppClientID = $Env:MS_ENTRA_GRAPH_CLIENT_ID  # get the client ID from the environment variable
$entraAppTenantID = $Env:MS_ENTRA_GRAPH_TENANT_ID  # get the tenant ID from the environment variable
$entraAppCertThumbprint = $Env:MS_ENTRA_GRAPH_CERTIFICATE_THUMBPRINT  # get the app certificate thumbprint from the environement variable
Connect-MgGraph -ClientID $entraAppClientID -TenantID $entraAppTenantID -CertificateThumbprint $entraAppCertThumbprint -NoWelcome  # make the connection via MS Graph

$users = Get-Content -Path $InputPath  # read the input file and store the emails in users

# First we want to go through the current licensed users for the higher SKU, and remove any that don't have a matching entry in our input file
$higherLicensedUsers = Get-MgUser -Filter "assignedLicenses/any(x:x/skuId eq $higherSkuID)" -ConsistencyLevel eventual -All | Select-Object UserPrincipalName  # get all users with the higher SKU license
foreach ($email in $higherLicensedUsers.UserPrincipalName)  # go through each user in the list of licensed users
{
    try 
    {
        if ($users -contains $email)  # if the licensed user is in the list of those who should have it, dont need to do anything
        {
            $message = "DBUG: $email has the higher license of SKU ID $higherSkuID and is still on the list of users who should, no changes needed"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append  # output to log
        }
        else 
        {
            $message = "INFO: $email has the higher license of SKU ID $higherSkuID but is not on the list of users who should, it will be removed"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append  # output to log
            Set-MgUserLicense -UserId $email -AddLicenses @{} -RemoveLicenses @($higherSkuID)  # remove the license from the user
            $successMessage = "INFO: License for $higherSkuID has been successfully removed from $email"
            $successMessage | Out-File -FilePath $localLog -Append 
        }
    }
    catch 
    {
        $message = "ERROR while trying to check or remove higher SKU license for $email"
        Write-Output $message  # output message to console
        $message | Out-File -FilePath $localLog -Append  # output message to log file
        Write-Output $_.Exception.Message  # output actual error to console
        $_.Exception.Message | Out-File -FilePath $localLog -Append  # output actual error to log file
    }
}
# Then do the opposite, go through the list of users who should have higher tier licenses, add any that dont already have it
foreach ($email in $users)
{
    try 
    {
        if ($higherLicensedUsers.UserPrincipalName -contains $email)  # if the user is found in the current licensed users
        {
            $message = "DBUG: $email already has a higher license of SKU ID $higherSkuID, no changes needed"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append  # output to log
        }
        else 
        {
            $message = "INFO: $email does not currently have a license for SKU ID $higherSkuID but is on the list of users who should, one will be assigned"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append
            # check if they have the old SKU assigned, need to remove it if so since it conflicts.
            $existingLicense = Get-MgUserLicenseDetail -UserID $email
            foreach ($skuID in $existingLicense.SkuId)
            {
                if (($skuID -eq $oldSkuID) -or ($skuID -eq $basicSkuID))
                {
                    $message = "INFO: $email has a license belonging to a conflicting SKU ID $skuID, it will be removed before assignment of new license"
                    Write-Output $message
                    $message | Out-File -FilePath $localLog -Append
                    try 
                    {
                        Set-MgUSerLicense -UserID $email -RemoveLicenses @($SkuID) -AddLicenses @{}
                    }
                    catch 
                    {
                        $message = "ERROR while trying to unassign conflicting license $skuID for $email"
                        Write-Output $message  # output message to console
                        $message | Out-File -FilePath $localLog -Append  # output message to log file
                        Write-Output $_.Exception.Message  # output actual error to console
                        $_.Exception.Message | Out-File -FilePath $localLog -Append  # output actual error to log file
                    }
                }
            }
            Set-MgUserLicense -UserId $email -AddLicenses @{SkuId= $higherSkuID} -RemoveLicenses @()  # assign the higher license to the user
            $successMessage = "INFO: License for $higherSkuID has been successfully assigned to $email"
            $successMessage | Out-File -FilePath $localLog -Append
        }
    }
    catch
    {
        $message = "ERROR while trying to check for or assign higher license of SKU ID $higherSkuID for $email"
        Write-Output $message  # output message to console
        $message | Out-File -FilePath $localLog -Append  # output message to log file
        Write-Output $_.Exception.Message  # output actual error to console
        $_.Exception.Message | Out-File -FilePath $localLog -Append  # output actual error to log file
    }
}
# Finally, go through all other unlicensed active users in the domain and try to give them the basic license
$unlicensedUsers = Get-MgUser -Filter "assignedLicenses/`$count eq 0 and userType eq 'Member' and AccountEnabled eq true" -ConsistencyLevel eventual -CountVariable unlicensedUserCount -All
foreach  ($user in $unlicensedUsers)  # go through just their emails
{
    $email = $user.UserPrincipalName
    $name = $user.DisplayName
    if ($name -ne 'On-Premises Directory Synchronization Service Account')  # ignore the service accounts, as there are some duplicates that cause errors
    {
        try 
        {
            $message = "INFO: $email does not currently have any licenses, they will be assigned one from SKU ID $basicSkuID, one will be assigned"
            Write-Output $message
            $message | Out-File -FilePath $localLog -Append

            Update-MgUser -UserId $email -UsageLocation 'US'  # update the users usage location to the US. Users must have a location before they can have a license

            Set-MgUserLicense -UserId $email -AddLicenses @{SkuId= $basicSkuID} -RemoveLicenses @()
            $successMessage = "INFO: License for $basicSkuID has been successfully assigned to $email"
            Write-Output $successMessage | Out-File -FilePath $localLog -Append
        }
        catch
        {
            $message = "ERROR while trying to assign basic license of SKU ID $basicSkuID for $email"
            Write-Output $message  # output message to console
            $message | Out-File -FilePath $localLog -Append  # output message to log file
            Write-Output $_.Exception.Message  # output actual error to console
            $_.Exception.Message | Out-File -FilePath $localLog -Append  # output actual error to log file
        }
    }
}

Disconnect-MgGraph  # disconnect from MS Graph