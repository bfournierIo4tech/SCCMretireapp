<#
#=======================================================================================
# Name: RetireApplication.ps1
# Version: 0.1
# Author: Raphael Perez - raphael@rflsystems.co.uk
# Date: 16/01/2014
# Comment: This script will retire a selected application
#
# Test: This script was tested on a Windows Server 2012 R2 running CM12R2 Primary site
#
# Updates:
#        0.1 - Raphael Perez - 16/01/2014 - Initial Script
#        1.0 - io4Master- 22-03-2019 - Modifications
#
# Usage:
#	 Option 1: powershell.exe -ExecutionPolicy Bypass .\RetireApplication.ps1 [Parameters]
#        Option 2: Open Powershell and execute .\RetireApplication.ps1 [Parameters]
#
# Parameters:
#		 sdkserver - netbios format
#		 sitenamespace - root\site\site_rfl format
#		 modelname - 
#
# Examples:
#        .\RetireApplication.ps1 
#=======================================================================================
#>
$sdkserver = $args[0]
$SiteNamespace = $args[1]
$SiteCode = $SiteNamespace.SubString($SiteNamespace.Indexof("site_") +5)
$modelname = $args[2]
$Scope = "Retired" #Path in Sccm Application Where you want to put retired application

$CMserver = ""
$ClientName = ""
$SRCServer = ""

$NewRootPath = "\\$CMserver\packages$\__Retired"
$localcachelocation = "C:\ProgramData\$ClientName\Sources\_Uninstall"
$localPKGExe = "Uninstall.exe"
$Dummyfolder = "\\$SRCServer\packages$\_UninstallOnly"


try
{
	if ($NewRootPath.substring($NewRootPath.length-1) -ne '\') { $NewRootPath+= '\' }
	"{0} {1} {2} {3} {4} {5}" -f $sdkserver, $SiteNamespace, $SiteCode, $modelname, $Scope, $NewRootPath

	if ((Read-Host "Are you really sure you want to retire the application? (Y/N)").Tolower() -eq "n")
	{
		Write-Host "Cancelled by the user, no action taken..." -ForegroundColor Red
		exit
	}

	$App  = Get-WmiObject -ComputerName "$sdkserver" -Class SMS_Application -Namespace "Root\SMS\Site_$SiteCode" -Filter "ModelName = '$modelname' and IsLatest='True'"
	if ($App -eq $null)
	{
		Write-Host "Invalid ModelName ($ModelName)" -ForegroundColor yellow
		exit
	}

	Write-Host "Importing CM12 powershell module..."
	import-module $env:SMS_ADMIN_UI_PATH.Replace("bin\i386","bin\ConfigurationManager.psd1") -force

	if ((get-psdrive $SiteCode -erroraction SilentlyContinue | measure).Count -ne 1)
	{
		new-psdrive -Name $SiteCode -PSProvider "AdminUI.PS.Provider\CMSite" -Root $sdkserver
	}
	cd "$($SiteCode):"
    $NewName = $App.LocalizedDisplayName

    #Get Application dirty information, so that we can use SDMPackageXML
    $App.get()

    #Deserialize SDMPackageXML
    $ApplicationXML = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::DeserializeFromString($App.SDMPackageXML, $true)

    ##Retiring App
	Write-host "Retiring application in SCCM Console"
	$App.SetIsExpired($true) | out-null
	Write-host " "
    
    ##Move Application to Retired folder
	Write-host "Moving Application to Folder $Scope in SCCM Console"
	$AppObj = Get-CMApplication -Name $NewName 
    $AppObj | Move-CMObject -FolderPath $SiteCode":\Application\"$Scope
            
	##Get All Deployment Type
	Write-host "Querying Deployment Type Information"
        

	Write-host "Getting source location information"
	if (($App.SDMPackageXML -eq $null) -or ($App.SDMPackageXML.trim() -eq ""))
	{
		Write-host "Unable to determine the current source location. ignoring moving content to retired folder" -ForegroundColor yellow
	}
	else
	{

		##get source folder and copy files to retired folder
		$xml = [xml]$App.SDMPackageXML
        $DeplName =@()
        $AppLocation = @()
                
        [Array]$DeplName = $xml.AppMgmtDigest.DeploymentType.Title
        [Array]$AppLocation = $xml.AppMgmtDigest.DeploymentType.Installer.Contents.Content.Location

        for ($i=0; $i -lt $DeplName.Count ; $i++)
        {
            $Loc=""
            $Loc=$AppLocation[$i].Substring(0,$AppLocation[$i].Length-1)
            $newPath = "$($NewRootPath)$($Loc.Substring($Loc.LastIndexOf("\")+1))"
            write-host "Application sources Location $AppLocation[$i]"
            if ((test-path $newPath) -eq (test-path $($AppLocation[$i]))) { Write-host "Same Paths - Already Retired" | out-null } else {
                Write-host "Creating retired path $newPath"                  
			   
			    if (!(Test-Path $newPath)) { [system.io.directory]::CreateDirectory($newPath) | out-null }
			    New-PSDrive -Name source -PSProvider FileSystem -Root $AppLocation[$i] | Out-Null
			    New-PSDrive -Name target -PSProvider FileSystem -Root $newPath | Out-Null
			    Write-host "Copying files $($AppLocation[$i]) to $newPath"
                Copy-Item -Path source:\*.* -Destination target: -recurse
                
			    Remove-PSDrive source
			    Remove-PSDrive target
                }
            


			##Change location in XML (Local Cache)
            #$newuninstallpath = join-path($localcachelocation,$DeplName)
            
            Write-host "Changing application source folder to $Dummyfolder"
            $ApplicationXML.DeploymentTypes.Installer[$i].Contents[0].Location = $Dummyfolder+"\"

            $ApplicationXML.DeploymentTypes.Installer[$i].UninstallCommandLine = $localcachelocation+$DeplName[$i].'#text'+"\"+$localPKGExe
            $ApplicationXML.DeploymentTypes.Installer[$i].UninstallContent =$null
            $ApplicationXML.DeploymentTypes.Installer[$i].UninstallSetting="NoneRequired"


			#delete source directory
			
            if ((test-path $newPath) -eq (test-path $($AppLocation[$i]))) { Write-host "Same Paths - Already Retired" | out-null } else { 
                Write-host "Deleting original source folder $($AppLocation[$i])"
                New-PSDrive -Name source -PSProvider FileSystem -Root ($AppLocation[$i].Substring(0,$AppLocation[$i].LastIndexOf("\"))) | Out-Null
                Get-ChildItem -Path source:\"$($AppLocation[$i].Substring($AppLocation[$i].LastIndexOf("\")+1))" -Recurse | Remove-Item -force -Recurse
			    remove-item -Path source:\"$($AppLocation[$i].Substring($AppLocation[$i].LastIndexOf("\")+1))" -Force
                Remove-PSDrive source
                }
			
        }
    write-host "Update Application Properties"
    $UpdatedXML = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::SerializeToString($ApplicationXML, $true)
	$App.SDMPackageXML = $UpdatedXML
	#$App.Put()
	}


	##Get all Deployments
	Write-host "Querying Deployment information"
	$DeploymentList = Get-CMDeployment | where {$_.ModelName -eq $($modelname)}

	foreach ($Deployment in $DeploymentList)
	{
		Write-host "Removing DeploymentID $($Deployment.DeploymentID)"
		Remove-CMDeployment -DeploymentId $Deployment.DeploymentID -ApplicationName $NewName -Force
	}

	##Remove Content From Distribution Point
    Write-host "Retreving Distribution Point for application $NewName"
        
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
            #Bug DP test une nouvelle facon d'obtenir le nom du DP
            $DPName = (Get-CMDistributionPointInfo | ? { $_.NALPath -eq $DPinfo.ServerNALPath}).Name
            Write-host "Removing ""$NewName"" package content from distribution point:"$DPName

            #Remove-CMContentDistribution -ApplicationName "$NewName" -DistributionPointName "$DPName" -Force 
        }
    }


}
catch
{
	Write-host "Something bad happen that I don't know about" -ForegroundColor red
	Write-host "The following error happen, no futher action taken" -ForegroundColor red
	$errorMessage = $Error[0].Exception.Message
	$errorCode = "0x{0:X}" -f $Error[0].Exception.ErrorCode
    	Write-host "Error $errorCode : $errorMessage"  -ForegroundColor red
    	Write-host "Full Error Message Error $($error[0].ToString())" -ForegroundColor red
	$Error.Clear()
}
finally
{ 
	Write-Host "Complete. Press any key to continue ..."
	$x = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
} 
