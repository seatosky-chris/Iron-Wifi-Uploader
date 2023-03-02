#####################################################################
$DBConnString = "Data Source=<SERVER\DATA SOURCE>;Database=<DATABASE>;Integrated Security=True;ApplicationIntent=ReadOnly"
$APIUrl = "https://us-west1.ironwifi.com/api/"
$APIKey = "<API KEY>" # The iron wifi api key
$MemberQuery = "SELECT MemberCode, LastName FROM Database.dbo.Members WHERE MemberStatus IN (1)" # The sql query that returns the list of members

# ITG details just for updating the Last Run asset
$ITG_APIKEy =  ""
$ITG_APIEndpoint = "https://api.itglue.com"
$orgID = ""
$ScriptsLastRunFlexAssetName = "Scripts - Last Run"
$LastUpdatedUpdater_APIURL = ""
####################################################################

# Ensure they are using the latest TLS version
$CurrentTLS = [System.Net.ServicePointManager]::SecurityProtocol
if ($CurrentTLS -notlike "*Tls12" -and $CurrentTLS -notlike "*Tls13") {
	[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
	Write-Host "This device is using an old version of TLS. Temporarily changed to use TLS v1.2."
}

$UserExport = Invoke-Sqlcmd -Query $MemberQuery -ConnectionString $DBConnString

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
$UsersAPI = $APIUrl + "users"
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
	# Replace the existing connector if it exists
	if ($Response._embedded.connectors) {
		foreach ($Connector in $Response._embedded.connectors) {
			if ($Connector.name -like "Guest Wifi CSV") {
				$ID = $Connector.id

				if ($ID) {
					$ConnectorBody = @{
						filename = "guest_wifi.csv"
						csvFile = "data:text/csv;base64,$WifiCSV_Encoded"
					} | ConvertTo-Json
			
					$Success = $false
					try {
						Invoke-RestMethod -Uri ($ConnectorsAPI + "/" + $ID) -Method 'PATCH' -Headers $APIHeaders -Body $ConnectorBody -ContentType 'application/json'
						Write-Host "Updated connector, ID: $($ID)" -ForegroundColor Green
						$Success = $true
					} catch {
						Write-Host "Could not upload the list of users for the reason: " + $_.Exception.Message -ForegroundColor Red
						Write-Error "Could not upload the list of users for the reason: " + $_.Exception.Message
					}
				}
			}
		}
	}

	if (
		$Response -and $Response._embedded -and $Response._embedded.PSobject.Properties.Name -contains "connectors" -and 
		(($Response._embedded.connectors | Measure-Object).Count -eq 0 -or $Response._embedded.connectors.name -notlike "Guest Wifi CSV")
	) {
		# Send the create connector api command
		$ConnectorBody = @{
			name = "Guest Wifi CSV"
			dbtype = "csv"
			filename = "guest_wifi.csv"
			csvFile = "data:text/csv;base64,$WifiCSV_Encoded"
		} | ConvertTo-Json

		$Success = $false
		try {
			$Response = Invoke-RestMethod -Uri $ConnectorsAPI -Method 'POST' -Headers $APIHeaders -Body $ConnectorBody -ContentType 'application/json'
			Write-Host "Created new connector, ID: $($Response.id)" -ForegroundColor Green
			$Success = $true
		} catch {
			Write-Host "Could not upload the list of users for the reason: " + $_.Exception.Message -ForegroundColor Red
			Write-Error "Could not upload the list of users for the reason: " + $_.Exception.Message
		}
	}
}

if ($Success -and $ITG_APIKEy -and $ITG_APIEndpoint -and $orgID -and $ScriptsLastRunFlexAssetName -and $LastUpdatedUpdater_APIURL) {
	If (Get-Module -ListAvailable -Name "ITGlueAPI") { 
		Import-module ITGlueAPI 
	} else { 
		Install-Module ITGlueAPI -Force
		Import-Module ITGlueAPI
	}

	Add-ITGlueBaseURI -base_uri $ITG_APIEndpoint
	Add-ITGlueAPIKey $ITG_APIKEy
	$ScriptsLastRunFilterID = (Get-ITGlueFlexibleAssetTypes -filter_name $ScriptsLastRunFlexAssetName).data
	Write-Host "Configured the ITGlue API"

	if ($ScriptsLastRunFilterID -and $orgID) {
		$LastUpdatedPage = Get-ITGlueFlexibleAssets -filter_flexible_asset_type_id $ScriptsLastRunFilterID.id -filter_organization_id $orgID

		if ($LastUpdatedPage -and $LastUpdatedPage.data) {
			$CustomScriptsTxt = $LastUpdatedPage.data.attributes.traits."custom-scripts"
			if ($CustomScriptsTxt -is [array]) {
				$CustomScriptsTxt = $CustomScriptsTxt -join "`n"
			}

			if ($CustomScriptsTxt -like "*Iron Wifi Updater: *") {
				$CustomScriptsTxt = $CustomScriptsTxt -replace "(<div>)?Iron Wifi Updater: .*?(\n|<\/div>|$)", ""
			}
			$CustomScriptsTxt += "Iron Wifi Updater: $((Get-Date).ToString("yyyy-MM-dd"))"

			$Headers = @{
				"x-api-key" = $ITG_APIKEy
			}
			$Body = @{
				"apiurl" = $ITG_APIEndpoint
				"itgOrgID" = $orgID
				"HostDevice" = $env:computername
				"custom-scripts" = $CustomScriptsTxt
			}
		
			$Params = @{
				Method = "Post"
				Uri = $LastUpdatedUpdater_APIURL
				Headers = $Headers
				Body = ($Body | ConvertTo-Json)
				ContentType = "application/json"
			}			
			Invoke-RestMethod @Params 
		}
	}
}

Write-Host "Script completed. Exiting..."