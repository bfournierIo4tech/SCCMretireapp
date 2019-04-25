<#
#=======================================================================================
# Name: RetireApplication.ps1
# Comment: This script will retire a selected application
#
# Updates:
#        0.1 - Raphael Perez - 16/01/2014 - Initial Script
#        1.0 - io4Master- 22-03-2019 - Modifications
#        1.1 - io4Master- 27-03-2019 - Modifications AD Group/ delete collection
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

#$ADSearchPath : If you want to restain script to search specific OU 
$ADSearchPath = "OU=Applications,OU=SCCM_Workstations,OU=Global Groups,OU=Groups,DC=corp,DC=contoso,DC=com"
$ADRetiredPath = "OU=Retired,OU=Applications,OU=SCCM_Workstations,OU=Global Groups,OU=Groups,DC=corp,DC=contoso,DC=com"


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
    $OriginalXML = $ApplicationXML #To compare for put()
    
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
        if ($OriginalXML -ne $ApplicationXML)
        {
            write-host "Update Application Properties"
            $UpdatedXML = [Microsoft.ConfigurationManagement.ApplicationManagement.Serialization.SccmSerializer]::SerializeToString($ApplicationXML, $true)
	        $App.SDMPackageXML = $UpdatedXML
	        $App.Put()
        }
        else
        {
	        write-host "No need to update Application Properties" -ForegroundColor Yellow
        }
}


	##Get all Deployments
	Write-host "Querying Deployment information"
	$DeploymentList = Get-CMDeployment | where {$_.ModelName -eq $($modelname)}

	foreach ($Deployment in $DeploymentList)
	{
		Write-host "Removing DeploymentID $($Deployment.DeploymentID)"
		Remove-CMDeployment -DeploymentId $Deployment.DeploymentID -ApplicationName $NewName -Force
	}

	##Get all Collections
    Write-host "Querying Deployment Collections information"
    $CollectionsToDelete =  $DeploymentList.CollectionName | ? {$_ -like $($NewName)+"_Computer*"}

	foreach ($Collection in $CollectionsToDelete)
	{
		Write-host "Removing Collection $($Collection)"
		Remove-CMCollection -Name "$Collection" -Force
	}

    ## Moving or removing AD Group
    #Check Rule Name
    Write-host "Querying AD Group Deployment information"
    $ADGroupName = (Get-CMDeviceCollectionQueryMembershipRule -CollectionName ($CollectionToDelete | ? {$_ -eq $($NewName)+"_Computer"})).RuleName
    if ($ADGroupName.Count -eq 0 -OR $ADGroupName -notlike '_SCCM_Computer_*')
    {
        #Check Description  for group ID
        [string]$ADGroupName="_SCCM_Computer_"+(($App.LocalizedDescription.Split(":")) | select -Last 1)

    }

    if ($ADGroupName.Count -eq 1)
    {
        Write-host "Foud AD Group" $ADGroupName
        $ADGroupObj = get-ADgroup -Filter "samaccountname -eq '$GroupName'" -SearchBase $ADSearchPath
        $ADGroupMembers = Get-ADGroupMember -Identity $ADGroupObj
        if ($ADGroupMembers.count -gt 0){
            #Move Group
            $TmpString ="AD Group: """+$GroupName+""" contain member ... moving to retired folder"
            write-host $TmpString
            Move-ADObject -Identity $ADGroupObj -TargetPath $ADRetiredPath 

        }
        else
        {
            #Delete group
            $TmpString= "AD Group: """+$GroupName+""" contain no member ... removing group"
            write-host $TmpString
            Remove-AdGroup -Identity $ADGroupObj -Confirm 
        } 
    }
    else { Write-host "No AD  Group Found" }


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

            Remove-CMContentDistribution -ApplicationName "$NewName" -DistributionPointName "$DPName" -Force 
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
  
