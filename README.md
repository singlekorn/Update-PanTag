# Update-PanTag
This was created because I use a policy based forwarding policy which uses tags to select a primary ISP for some source IP addresses on my network.  I regularly need to change my primary ISP for development purposes without using L2 methods (switching SSID/VLAN).

- Get the active IP Addresses of the Windows Device this script is run on (Tested only with PS 7.2.6).
- Find the matching Address Objects in PAN-OS.
- Strip the ISP routing tags off these objects and add the one decided by this script.
- Commit the configuration.
- Watch the commit job until it is complete.

## Usage Example
`./Update-PanTag.ps1 -isp cl`

## PAN-OS AuthN & AuthZ

- Create a dedicated **Admin Role** with ONLY the following permissions (you need to manually deny everything else):
```
XML API
    Operational Requests (needed to check status of submitted jobs)
    Commit
REST API
    Addresses
```
- Use a dedicated **Administrator** account for this script:
    - Password (only used one-time to generate your API key)
    - Administrator Type: Role Based
    - Profile: Use the **Admin Role** you created in the previous step

## Initial Script Configuration

- Update the following static script inputs for your PAN-OS device management IP and however you are storing the API key.
    - NOTE: This script will FAIL unless you have setup TLS properly.

```
$hostName = 'fw1.tg.1korn.io'
$apiKey = Import-Clixml './apikey.clixml'
```

- Update the tagging map.  This does several things:
    - Provides an easy way to use the script without having to know your Tag names.
    - Create mutually exclusive tags for a single object.  All of these tags are stripped from an object before the correct tag is added.

```
$tagMap = @{
    'cl' = 'Primary-CL'
    'sl' = 'Primary-SL'
}
```