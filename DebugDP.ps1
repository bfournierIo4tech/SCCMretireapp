#
# Press 'F5' to run this script. Running this script will load the ConfigurationManager
# module for Windows PowerShell and will connect to the site.
#
# This script was auto-generated at '3/18/2019 4:36:13 PM'.

# Uncomment the line below if running in an environment where script signing is 
# required.
#Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

# Site configuration
$SiteCode = "CHQ" # Site code 
$ProviderMachineName = "CM1.corp.contoso.com" # SMS Provider machine name

# Customizations
$initParams = @{}
#$initParams.Add("Verbose", $true) # Uncomment this line to enable verbose logging
#$initParams.Add("ErrorAction", "Stop") # Uncomment this line to stop the script on any errors

# Do not change anything below this line

# Import the ConfigurationManager.psd1 module 
if((Get-Module ConfigurationManager) -eq $null) {
    Import-Module "$($ENV:SMS_ADMIN_UI_PATH)\..\ConfigurationManager.psd1" @initParams 
}

# Connect to the site's drive if it is not already present
if((Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue) -eq $null) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderMachineName @initParams
}


# Set the current location to be the site code.
Set-Location "$($SiteCode):\" @initParams

$sdkserver ="CM1" 
$SiteNamespace="root\sms\site_CHQ" 
$AppName="2 dep msi test 3-copy"
$modelname=(Get-CMApplication -Name $AppName).ModelName

##Remove Content From Distribution Point
Write-host "Retreving Distribution Point for application $AppName"
        
$distributionPoint= Get-WmiObject -ComputerName $sdkserver -Namespace root\sms\site_$SiteCode -Query "SELECT * FROM SMS_PackageStatusDistPointsSummarizer where SecureObjectID = '$modelname'"
if ($distributionPoint.count -eq 0)
{
    Write-host "Application not found on any distribution Point"
}
else
{
    foreach ( $DPinfo in $distributionPoint)
    {
        #$DPName = ([regex]::match($DPinfo.ServerNALPath,'Display=\\\\(.*?)\\"]MSWNET')).Groups[1].Value
        $DPName = (Get-CMDistributionPointInfo | ? { $_.NALPath -eq $DPinfo.ServerNALPath}).Name
        Write-host "Removing ""$AppName"" package content from distribution point:"$DPName

        Remove-CMContentDistribution -ApplicationName "$AppName" -DistributionPointName "$DPName" -Force -WhatIf
    }
}

    
