# TODO - Add functionality to deploy SonarQube in multiple ways: WebApp with containers, VM, K8s etc.

function New-AuthHeader {

    param(
        [Parameter(ParameterSetName = "credentials", Mandatory = $True)]
        [string]$username,
        [string]$password,
        [Parameter(ParameterSetName = "token", Mandatory = $True)]
        [string]$token
    )

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    switch ($PSBoundParameters.Keys) {
        'username' { $encodedString = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$($username):$($password)")) }

        'token' { $encodedString = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes("$token")) }
    }

    $Header = @{
        Authorization = "Basic $encodedString"
    }
    return $Header
}

function Get-SonarQubeInfo {

    param(
        [Parameter(Mandatory = $true)]
        $Uri,
        [Parameter(Mandatory = $true)]
        $Header,
        [Parameter(ParameterSetName = "serverVersion", Mandatory = $True)]
        [switch]$serverVersion,
        [Parameter(ParameterSetName = "serverStatus", Mandatory = $True)]
        [switch]$serverStatus,
        [Parameter(ParameterSetName = "dbMigrationStatus", Mandatory = $True)]
        [switch]$dbMigrationStatus,
        [Parameter(ParameterSetName = "systemUpgrades", Mandatory = $True)]
        [switch]$systemUpgrades
    )

    switch ($PSBoundParameters.Keys) {
        'serverVersion' { $apiUrl = 'system/status'; $option = "version" }

        'serverStatus' { $apiUrl = 'system/status'; $option = "status" }

        'dbMigrationStatus' { $apiUrl = 'system/db_migration_status'; $option = 'state' }

        'systemUpgrades' { $apiUrl = 'system/upgrades'; $option = 'upgrades' }
    }

    try {
        $response = Invoke-WebRequest -Uri "$Uri/api/$apiUrl" -Method Get -Headers $Header -ErrorVariable ResponseError
    }
    catch {

    }

    if ($response.StatusCode -eq 200) {

        $status = $response.Content | ConvertFrom-Json
        $status.$option
    }
    else {
        Write-Host $ResponseError.Message -ErrorAction Stop
        return "Error" 
    }

}

function Wait-SonarQubeStart {
    param (
        [ValidateNotNullOrEmpty()]$Uri,
        [ValidateNotNullOrEmpty()]$Header
    )
    
    if (!(Get-Command Get-SonarQubeInfo)) {
        Write-Output "Did not found prerequisite cmdlet, stoping execution"
        exit
    }

    $started = $false
    Do {
        
        $status = Get-SonarQubeInfo -Uri $Uri -Header $Header -serverStatus 

        switch ($status) {
            'UP' { Write-Output "SonarQube status: $status SonarQube Online!" ; $started = $true }
            'DOWN' { Write-Output "SonarQube is down for some reason, please review the logs for details"; exit }
            { $_ -in 'STARTING', 'RESTARTING', 'DB_MIGRATION_RUNNING' } { Write-Output "SonarQube status: $status, waiting for SonarQube service to start.." ; Start-Sleep -Seconds 5 }
            { $_ -in 'DB_MIGRATION_NEEDED' } { Write-Output "Your SonarQube needs a dbschema migration, stopping"; exit }
            { $_ -in 'Error' } { Write-Output "SonarQube status: $status, waiting for SonarQube service to start.." ; Start-Sleep -Seconds 5 }
        }

    }
    Until ($started)
}

function Restart-SonarQubeServer {
    param (
        $Uri,
        $Header
    )
    try {

        $response = Invoke-WebRequest -Uri "$Uri/api/system/restart" -Method Post -Headers $Header -ErrorVariable ResponseError
    }
    catch {

    }

    if ($response.StatusCode -eq 200) {

        Write-Output "Restarting SonarQube server, please wait.."
        $status = $response.Content | ConvertFrom-Json
        $status

    }
    else {
        Write-Host $ResponseError.Message -ErrorAction Stop
        return "Error"
    }

}

function Get-SonarQubePlugins {
    <#
    .SYNOPSIS
        Function used to get a list of SonarQube plugins
    .DESCRIPTION
        Gets a list of SonarQube plugins based on corresponding parameter given (e.g. Available, Installed, etc.). 
        It can be used in conjunction with Update-SonarQube plugins or other cmdlets inside this module.
    .EXAMPLE
        Get-SonarQubePlugins -Uri https://mysonar.com -Header (New-AuthHeader -username sonaruser -password mypassword) -Installed
    .EXAMPLE
        Get-SonarQubePlugins -Uri https://mysonar.com -Header (New-AuthHeader -username sonaruser -password mypassword) -RequireUpdate -Compatible
    #>
    param(
        [ValidateNotNullOrEmpty()]$Uri,
        [ValidateNotNullOrEmpty()]$Header,
        # TODO - If no switch is added list all
        [Parameter(ParameterSetName = "Available", Mandatory = $True)]
        [switch]$Available,
        [Parameter(ParameterSetName = "Installed", Mandatory = $True)]
        [switch]$Installed,
        [Parameter(ParameterSetName = "RequireUpdate", Mandatory = $True)]
        [switch]$RequireUpdate,
        [switch]$Compatible,
        [Parameter(ParameterSetName = "Pending", Mandatory = $True)]
        [switch]$Pending
    )

    switch ($PSBoundParameters.Keys) {
        'Available' { $apiUrl = 'plugins/available'; }

        'Installed' { $apiUrl = 'plugins/installed'; }

        'RequireUpdate' { $apiUrl = 'plugins/updates'; }

        'Pending' { $apiUrl = 'plugins/pending'; }
    }

    try {

        $response = Invoke-WebRequest -Uri "$Uri/api/$apiUrl" -Method Get -Headers $Header -ErrorVariable ResponseError
    }
    catch {

    }

    if ($response.StatusCode -eq 200) {

        $status = $response.Content | ConvertFrom-Json
        if ($Compatible) {
            
            $status.plugins | Where-Object { $_.updates.status -eq "COMPATIBLE" }
        }
        else {
            $status.plugins
        }

        $sysUpgradePlugins = $status.plugins | Where-Object { $_.updates.status -eq "REQUIRES_SYSTEM_UPGRADE" }

        if ($null -ne $sysUpgradePlugins -and $false -eq $Compatible) {
            Write-Warning "Some plugins need a SonarQube server upgrade:" -WarningAction Continue
            $sysUpgradePlugins
        }

    }
    else {
        Write-Host $ResponseError.Message -ErrorAction Stop
        return "Error" 
    }

}

function Install-SonarQubePlugin {
    param(
        [ValidateNotNullOrEmpty()]$Uri,
        [ValidateNotNullOrEmpty()]$Header,
        [ValidateNotNullOrEmpty()][array]$key
    )

    foreach ($item in $key) {
        try {

            $response = Invoke-WebRequest -Uri "$Uri/api/plugins/install?key=$item" -Method Post -Headers $Header -ErrorVariable ResponseError
        
        }
        catch {

        }

        if ($response.StatusCode -eq 204) {

            Write-Output "Plugin $item added, it will be installed the next time SonarQube server restarts"
            $status = $response.Content | ConvertFrom-Json
            $status

        }
        else {
            Write-Host $ResponseError.Message -ErrorAction Stop
            return "Error"
        }
    }
}

function Update-SonarQubePlugin {
    param(
        [ValidateNotNullOrEmpty()]$Uri,
        [ValidateNotNullOrEmpty()]$Header,
        [ValidateNotNullOrEmpty()][array]$key
    )

    foreach ($item in $key) {
        try {

            $response = Invoke-WebRequest -Uri "$Uri/api/plugins/update?key=$item" -Method Post -Headers $Header -ErrorVariable ResponseError
        
        }
        catch {

        }

        if ($response.StatusCode -eq 204) {

            Write-Output "Plugin $item will be updated the next time SonarQube server restarts"
            $status = $response.Content | ConvertFrom-Json
            $status

        }
        else {
            Write-Host $ResponseError.Message -ErrorAction Stop
            return "Error"
        }
    }
}

function Uninstall-SonarQubePlugin {
    param(
        [ValidateNotNullOrEmpty()]$Uri,
        [ValidateNotNullOrEmpty()]$Header,
        [ValidateNotNullOrEmpty()][array]$key
    )

    foreach ($item in $key) {
        try {

            $response = Invoke-WebRequest -Uri "$Uri/api/plugins/uninstall?key=$item" -Method Post -Headers $Header -ErrorVariable ResponseError
        
        }
        catch {

        }

        if ($response.StatusCode -eq 204) {

            Write-Output "Plugin $item will be uninstalled the next time SonarQube server restarts"
            $status = $response.Content | ConvertFrom-Json
            $status

        }
        else {
            Write-Host $ResponseError.Message -ErrorAction Stop
            return "Error"
        }
    }
}


function Migrate-SonarQube {
    param(
        [ValidateNotNullOrEmpty()]$Uri,
        [ValidateNotNullOrEmpty()]$Header,
        [Parameter(ParameterSetName = "databaseSchema", Mandatory = $True)]
        [switch]$databaseSchema,
        [Parameter(ParameterSetName = "plugins", Mandatory = $True)]
        [switch]$plugins
    )

    if (!(Get-Command Get-SonarQubeInfo)) {
        Write-Output "Did not found prerequisite cmdlet, stoping execution"
        exit
    }

    switch ($PSBoundParameters.Keys) {
        'databaseSchema' { 

            $status = (Get-SonarQubeInfo -Uri $Uri -Header $Header -dbMigrationStatus)

            switch ($status) {
                'NO_MIGRATION' { Write-Output "SonarQube has already the latest database schema, nothing to do." }
                'NOT_SUPPORTED' { Write-Output "Database migration is not supported." }
                'MIGRATION_RUNNING' { Write-Output "Database migration running, give it a few minutes and check back." }
                'MIGRATION_SUCCEEDED' { Write-Output "Database migration succeeded, nothing to do." }
                'MIGRATION_FAILED' { 
                    # TODO - maybe add functionality to resore the database automagically?
                    Write-Output "Database migration failed. Consider restoring the database from a previous point in time and try again."  
                }
                'MIGRATION_REQUIRED' { 

                    $apiUrl = 'system/migrate_db';

                    try {

                        $response = Invoke-WebRequest -Uri "$Uri/api/$apiUrl" -Method POST -Headers $Header -ErrorVariable ResponseError
                    }
                    catch {

                    }

                    if ($response.StatusCode -eq 200) {

                        $status = $response.Content | ConvertFrom-Json
                        $status
                    }
                    else {
                        Write-Host $ResponseError.Message -ErrorAction Stop
                        return "Error" 
                    }
                }

                Default { }
                
            }
        }

        'plugins' { }
        Default { }
    }
}