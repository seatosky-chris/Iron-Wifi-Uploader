#####################################################################
$DBConnString = "Data Source=<SERVER\DATA SOURCE>;Database=<DATABASE>;Integrated Security=True;ApplicationIntent=ReadOnly"
$APIUrl = "https://us-west1.ironwifi.com/api/"
$APIKey = "<API KEY>" # The iron wifi api key
####################################################################

# Ensure they are using the latest TLS version
$CurrentTLS = [System.Net.ServicePointManager]::SecurityProtocol
if ($CurrentTLS -notlike "*Tls12" -and $CurrentTLS -notlike "*Tls13") {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	Write-Host "This device is using an old version of TLS. Temporarily changed to use TLS v1.2."
}

$Query = "SELECT MemberCode, LastName FROM Jonasnet.dbo.tblPvxMembers WHERE MemberStatus = 18" # The sql query that returns the list of members
$UserExport = Invoke-Sqlcmd -Query $Query -ConnectionString $DBConnString

$WifiCSV = @()

foreach ($User in $UserExport) {
	$Password = $User.LastName
	$WifiAccount = [PSCustomObject]@{
		'#"username"' = $User.MemberCode
		'firstname' = ''
		'lastname' = ''
		'email' = ''
		'group1|priority1,group2|priority2' = 'Guest Wifi Users|1'
		'att_check1|op1|value1,att_check2|op2|value2' = "Cleartext-Password|:=|$Password"
		'att_reply1|op1|value1,att_reply2|op2|value2' = ''
		'orgunit' = ''
		'client_mac1,client_mac2' = ''
	}
	$WifiCSV += $WifiAccount
}

$WifiCSV_Converted = $WifiCSV | ConvertTo-Csv -NoTypeInformation
$WifiCSV_Encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($WifiCSV_Converted -join [Environment]::NewLine))

$ConnectorsAPI = $APIUrl + "connectors"
$APIHeaders = @{
    Authorization="Bearer $APIKey"
	accept = "application/json"
}

# Get existing connectors
$Response = $false
try {
	$Response = Invoke-RestMethod -Uri $ConnectorsAPI -Method 'GET' -Headers $APIHeaders
} catch {
	Write-Host "Could not get the current list of connectors." -ForegroundColor Red
	Write-Error "Could not get the current list of connectors."
}

if ($Response) {
	# Delete existing connector if it exists
	if ($Response._embedded.connectors) {
		foreach ($Connector in $Response._embedded.connectors) {
			if ($Connector.name -like "Guest Wifi CSV") {
				$ID = $Connector.id
				if ($ID) {
					try {
						$Response = Invoke-RestMethod -Uri ($ConnectorsAPI + "/" + $ID + "?delete_users=true") -Method 'DELETE' -Headers $APIHeaders
						Write-Host "Deleted the existing connector successfully." -ForegroundColor Green
					} catch {
						Write-Host "Could not delete the existing connector." -ForegroundColor Red
						Write-Error "Could not delete the existing connector."
					}
				}
			}
		}
	}

	# Send the create connector api command
	$ConnectorBody = @{
		name = "Guest Wifi CSV"
		dbtype = "csv"
		filename = "guest_wifi.csv"
		csvFile = "data:text/csv;base64,$WifiCSV_Encoded"
	} | ConvertTo-Json

	try {
		$Response = Invoke-RestMethod -Uri $ConnectorsAPI -Method 'POST' -Headers $APIHeaders -Body $ConnectorBody -ContentType 'application/json'
		Write-Host "Created new connector, ID: ${$Response.id}" -ForegroundColor Green
	} catch {
		Write-Host "Could not upload the list of users for the reason: " + $_.Exception.Message -ForegroundColor Red
		Write-Error "Could not upload the list of users for the reason: " + $_.Exception.Message
	}
}

Write-Host "Script completed. Exiting..."