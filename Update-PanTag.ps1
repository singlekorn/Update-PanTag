# Update-PanTag.ps1
Param (
    [Parameter(Mandatory = $true, HelpMessage = "'cl' for CentryLink and 'sl' for StarLink")][string]$isp
)

# Script static inputs
$hostName = 'fw1.tg.1korn.io'
$apiKey = Import-Clixml './apikey.clixml'
$header = @{"X-PAN-KEY" = $apiKey }

# User input to tag mapping.  These are also all the tags that are stripped from the object before adding the one specified by $isp
$tagMap = @{
    'cl' = 'Primary-CL'
    'sl' = 'Primary-SL'
}

function Write-Log {
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline)][string]$out
    )

    # Color code the output based on the first word in the message
    $color = switch (($out).split()[0]) {
        INFO {
            'Gray'
        }
        WARN {
            'Yellow'
        }
        ERROR {
            'Red'
        }
        SUCCESS {
            'Green'
        }
        default {
            'White'
        }
    }
    
    Write-Host "$(((Get-PSCallStack)[-2]).Location): $out" -ForegroundColor $color

}

function Invoke-RestAPI {
    param (
        $uri,
        $method,
        $headers,
        $body
    )

    # Check 1: HTTPS Connectivity
    try {
        # WARNING: Writing the URI of an API call to a log may leak (and archive) sensitive information
        # "DEBUG Invoking REST Method: $method $uri" | Write-Log
        $result = Invoke-RestMethod -Uri $uri -Method $method -Headers $headers -Body $body
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        "ERROR Request Failed: $ErrorMessage" | Write-Log
        exit
    }
    
    # Check 2: Successful API Request
    if ($result.'@status' -eq "success") {
        return $result
    }
    else {
        "ERROR Status: $($result.'@status'): Terminating Script" | Write-Log
        exit
    }

}

function Invoke-XmlAPI {
    param (
        $uri,
        $method,
        $headers,
        $body
    )

    # Check 1: HTTPS Connectivity
    try {
        # WARNING: Writing the URI of an API call to a log may leak (and archive) sensitive information
        # "DEBUG Invoking XML Request: $method $uri" | Write-Log
        $result = Invoke-WebRequest -Uri $uri -Method $method -Headers $headers -Body $body
    }
    catch {
        $ErrorMessage = $_.Exception.Message
        "ERROR Request Failed: $ErrorMessage" | Write-Log
        break
    }
    
    # Check 2: Successful API Request
    if ($result.StatusCode -eq 200) {
        return $result
    }
    else {
        "ERROR Status: $($result.StatusCode): Terminating Script" | Write-Log
        break
    }

}

"Starting Script" | Write-Log

# Get Local Windows IP Addresses
$notAlias = '^(Bluetooth Network Connection|vEthernet|Loopback Pseudo-Interface)'
$myIps = (Get-NetIPAddress | Where-Object { $_.InterfaceAlias -notmatch $notAlias -and $_.AddressFamily -eq "IPv4" -and $_.AddressState -eq 'Preferred' } ).IPAddress

# Get PAN-OS Address Objects with matching IP via API
$uri = "https://$hostName/restapi/v10.0/Objects/Addresses?location=vsys&vsys=vsys1"
$response = Invoke-RestAPI -Uri $uri -Headers $header -method GET
$panObjects = $response.result.entry | Where-Object { $myIps -contains $_.'ip-netmask' }

if ($null -eq $panObjects) {

    "ERROR No Address Objects could be found in PAN-OS with the following $myIps. Script terminated with errors." | Write-Log
    exit
}

foreach ($panObject in $panObjects) {

    # Get list of tag members, excluding ones scoped in $tagMap
    $newTagMembers = $panObject.tag.member | Where-Object { $tagMap.values -notcontains $_ }
    
    # Add the new desired tag to the existing tags
    $newTagMembers += $tagMap[$isp]
    
    # Create a new object from the response, removing fields not needed in the Edit request, and using the new list of tag members
    $panNewObject = $panObject | Select-Object -ExcludeProperty '@location', '@vsys'
    $panNewObject.tag.member = $newTagMembers
    
    $entry = [PSCustomObject]@{
        entry = $panNewObject 
    }
    $body = $entry | ConvertTo-Json -Depth 10
    
    "INFO Updating `'$($panNewObject.'@name')`' with tag `'$($tagMap[$isp])`'" | Write-Log

    # Update the existing record
    $uri = [uri]::EscapeUriString("https://$hostName/restapi/v10.0/Objects/Addresses?location=vsys&vsys=vsys1&name=$($panNewObject.'@name')")
    $response = Invoke-RestAPI -Uri $uri -Headers $header -Method PUT -Body $body
}

# Commit the change in PAN-OS (yes, this is a swtich to the XML API... because PAN)
$uri = [uri]::EscapeUriString("https://$hostName/api/?type=commit&cmd=<commit></commit>")
$response = Invoke-XmlAPI -Uri $uri -Headers $header -Method GET

# Check the status of the Job in a while loop to provide feedback
if ($response.Content -like "*success*") {
    
    # Get the JobId out of the response
    $msgLine = $response.Content | Select-Xml -XPath "//msg//line" | ForEach-Object { $_.node.InnerXml }
    $jobId = ($msgLine -split 'Commit job enqueued with jobid ')[1]

    "INFO Commit Success: Checking on JobID $jobId for 10-min or until complete." | Write-Log

    $test = 0
    while ($test -ne 30) {
        Start-Sleep -Seconds 20
        $test++
            
        $uri = [uri]::EscapeUriString("https://$hostName/api/?type=op&cmd=<show><jobs><id>$jobId</id></jobs></show>")
        $response = Invoke-XmlAPI -Uri $uri -Headers $header -Method GET

        $result = $response.Content | Select-Xml -XPath "//result//result" | ForEach-Object { $_.node.InnerXml }
        $progress = $response.Content | Select-Xml -XPath "//result//progress" | ForEach-Object { $_.node.InnerXml }
            
        "INFO JobID $jobId Result $result $progress%." | Write-Log

        if ($result -eq 'OK') {
            "SUCCESS Script completed successfully." | Write-Log
            exit
        }
    }

    "WARN Timed out on JobID $jobId.  Script completed with warnings." | Write-Log
    exit
}
else {

    "ERROR Failed to commit job.  Script terminated with errors." | Write-Log
    exit
}
