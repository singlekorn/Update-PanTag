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

# Get Local IP Addresses
$notAlias = '^(Bluetooth Network Connection|vEthernet|Loopback Pseudo-Interface)'
$myIps = (Get-NetIPAddress | Where-Object { $_.InterfaceAlias -notmatch $notAlias -and $_.AddressFamily -eq "IPv4" -and $_.AddressState -eq 'Preferred' } ).IPAddress

# Get Address Objects with matching IP via API
$uri = "https://$hostName/restapi/v10.0/Objects/Addresses?location=vsys&vsys=vsys1"
$response = Invoke-RestMethod -Uri $uri -Headers $header -Method Get
$panObjects = $response.result.entry | Where-Object { $myIps -contains $_.'ip-netmask' }

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
    
    Write-Host "Updating `'$($panNewObject.'@name')`' with tag `'$($tagMap[$isp])`'"

    # Update the existing record
    $uri = [uri]::EscapeUriString("https://$hostName/restapi/v10.0/Objects/Addresses?location=vsys&vsys=vsys1&name=$($panNewObject.'@name')")
    $response = Invoke-RestMethod -Uri $uri -Headers $header -Method Put -Body $body
}

# Commit the change in PAN-OS (yes, this is a swtich to the XML API because PAN)
$uri = [uri]::EscapeUriString("https://$hostName/api/?type=commit&cmd=<commit></commit>")
$response = Invoke-RestMethod -Uri $uri -Headers $header -Method Get
Write-Output $response.InnerXml

# Get the JobId out of the response
$msgLine = $response.InnerXml | Select-Xml -XPath "//msg//line" | ForEach-Object { $_.node.InnerXml }
$jobId = ($msgLine -split 'Commit job enqueued with jobid ')[1]

# Check the status of the Job in a while loop to provide feedback
if ($response.InnerXml -like "*success*") {
    Write-Host "Checking on JobID $jobId for 10-min or until complete."
    $test = 0
    while ($test -ne 60) {
        Start-Sleep -Seconds 10
        $test++
            
        $uri = [uri]::EscapeUriString("https://$hostName/api/?type=op&cmd=<show><jobs><id>$jobId</id></jobs></show>")
        $response = Invoke-RestMethod -Uri $uri -Headers $header -Method Get

        $result = $response.InnerXml | Select-Xml -XPath "//result//result" | ForEach-Object { $_.node.InnerXml }
        $tfin = $response.InnerXml | Select-Xml -XPath "//result//tfin" | ForEach-Object { $_.node.InnerXml }
        $progress = $response.InnerXml | Select-Xml -XPath "//result//progress" | ForEach-Object { $_.node.InnerXml }
            
        Write-Output "Currently $result - $tfin - $progress% as of $(Get-Date -Format 'yyyy/MM/dd HH:mm:ss')"

        if ($result -eq 'OK') {
            break
        }
    }
}

