# Install the worker prerequisites and the worker-only CSV conversion tool.
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Custom Script Extension supplies the password through protected settings.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$SvcAzAutoPassword,

    [string]$SvcAzAutoAccountName = 'svc-azauto',

    [string]$PowerShellVersion = '7.4.13',

    [string]$PowerShellMsiUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.13/PowerShell-7.4.13-win-x64.msi', # VERIFY: confirm the current PowerShell 7.4 patch release URL.

    [ValidateNotNullOrEmpty()]
    [string]$ToolSourcePath = '.\Convert-Extract.ps1',

    [string]$PowerShellExecutablePath = 'C:\Program Files\PowerShell\7\pwsh.exe'
)

function ConvertTo-WorkerSecurePassword {
    [CmdletBinding()]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'Custom Script Extension supplies the password through protected settings; convert immediately for the local account API.')]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    return ConvertTo-SecureString -String $Password -AsPlainText -Force
}

function New-WorkerLocalAccount {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountName,

        [Parameter(Mandatory = $true)]
        [securestring]$Password
    )

    if (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) {
        $accountParameters = @{ Name = $AccountName; Password = $Password }
        Set-LocalUser @accountParameters
        return
    }

    # Matching local credentials on both workgroup VMs enable SMB pass-through authentication.
    if ($PSCmdlet.ShouldProcess($AccountName, 'Create local account')) {
        $accountParameters = @{
            Name = $AccountName
            AccountNeverExpires = $true
            PasswordNeverExpires = $true
            UserMayNotChangePassword = $true
            Password = $Password
        }
        New-LocalUser @accountParameters | Out-Null
    }
}

function Get-InstalledProductVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExecutablePath
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
        return $null
    }

    return (Get-Item -LiteralPath $ExecutablePath).VersionInfo.ProductVersion
}

function Install-VerifiedPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        [Parameter(Mandatory = $true)]
        [ValidateSet('.msi')]
        [string]$Extension,

        [Parameter(Mandatory = $true)]
        [string[]]$InstallerArguments
    )

    $packagePath = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString())$Extension"
    $originalSecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol

    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Uri -OutFile $packagePath -UseBasicParsing -ErrorAction Stop
        $signature = Get-AuthenticodeSignature -FilePath $packagePath
        if ($signature.Status -ne 'Valid') {
            throw "The downloaded package from '$Uri' does not have a valid Authenticode signature."
        }

        $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList (
            @('/i', "`"$packagePath`"") + $InstallerArguments
        ) -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -notin @(0, 3010)) {
            throw "The installer exited with code $($process.ExitCode)."
        }
    }
    finally {
        [System.Net.ServicePointManager]::SecurityProtocol = $originalSecurityProtocol
        Remove-Item -LiteralPath $packagePath -Force -ErrorAction SilentlyContinue
    }
}

function Install-WorkerPowerShell {
    [CmdletBinding()]
    param(
        [string]$PowerShellVersion,
        [string]$PowerShellMsiUrl,
        [string]$PowerShellExecutablePath
    )

    $installedVersion = Get-InstalledProductVersion -ExecutablePath $PowerShellExecutablePath
    if (-not $installedVersion -or
        -not $installedVersion.StartsWith($PowerShellVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        Install-VerifiedPackage -Uri $PowerShellMsiUrl -Extension '.msi' -InstallerArguments @('/quiet', '/norestart', 'ADD_PATH=1')
    }

    $finalVersion = Get-InstalledProductVersion -ExecutablePath $PowerShellExecutablePath
    if (-not $finalVersion -or
        -not $finalVersion.StartsWith($PowerShellVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PowerShell $PowerShellVersion was not found at the configured executable path after installation."
    }
}

function Get-WorkerToolPermissionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$AccountName
    )

    return @(
        [pscustomobject]@{
            IdentityName = 'BUILTIN\Administrators'
            FileSystemRights = 'FullControl'
        },
        [pscustomobject]@{
            IdentityName = "$ComputerName\$AccountName"
            FileSystemRights = 'ReadAndExecute'
        }
    )
}

function Get-WorkerToolAccessRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Principal.IdentityReference]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$Rights,

        [switch]$InheritToChildren
    )

    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::None
    if ($InheritToChildren) {
        $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    }

    return [System.Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        [System.Security.AccessControl.FileSystemRights]$Rights,
        $inheritanceFlags,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
}

function Set-WorkerToolPermission {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$AccountName,

        [switch]$InheritToChildren
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Set worker tool permissions')) {
        return
    }

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($accessRule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($accessRule)
    }

    foreach ($permission in Get-WorkerToolPermissionPlan -ComputerName $ComputerName -AccountName $AccountName) {
        $identity = [System.Security.Principal.NTAccount]::new($permission.IdentityName)
        $ruleParameters = @{
            Identity = $identity
            Rights = $permission.FileSystemRights
        }
        if ($InheritToChildren) {
            $ruleParameters.InheritToChildren = $true
        }
        [void]$acl.AddAccessRule((Get-WorkerToolAccessRule @ruleParameters))
    }

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Install-WorkerToolIfChanged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolSourcePath,

        [Parameter(Mandatory = $true)]
        [string]$ToolDestinationPath,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$AccountName
    )

    if (-not (Test-Path -LiteralPath $ToolSourcePath -PathType Leaf)) {
        throw "The worker tool was not found at '$ToolSourcePath'."
    }

    $destinationDirectory = Split-Path -Parent $ToolDestinationPath
    New-Item -Path $destinationDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null

    $copyTool = $true
    if (Test-Path -LiteralPath $ToolDestinationPath -PathType Leaf) {
        $sourceHash = (Get-FileHash -LiteralPath $ToolSourcePath -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $ToolDestinationPath -Algorithm SHA256).Hash
        $copyTool = $sourceHash -ne $destinationHash
    }

    if ($copyTool) {
        Copy-Item -LiteralPath $ToolSourcePath -Destination $ToolDestinationPath -Force -ErrorAction Stop
    }

    Set-WorkerToolPermission -Path $destinationDirectory -ComputerName $ComputerName `
        -AccountName $AccountName -InheritToChildren
    Set-WorkerToolPermission -Path $ToolDestinationPath -ComputerName $ComputerName -AccountName $AccountName
}

function Invoke-WorkerSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SvcAzAutoPassword,

        [string]$SvcAzAutoAccountName = 'svc-azauto',
        [string]$PowerShellVersion = '7.4.13',
        [string]$PowerShellMsiUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.13/PowerShell-7.4.13-win-x64.msi',
        [string]$ToolSourcePath = '.\Convert-Extract.ps1',
        [string]$PowerShellExecutablePath = 'C:\Program Files\PowerShell\7\pwsh.exe'
    )

    $passwordParameters = @{ Password = $SvcAzAutoPassword }
    $securePassword = ConvertTo-WorkerSecurePassword @passwordParameters
    $accountParameters = @{ AccountName = $SvcAzAutoAccountName; Password = $securePassword }
    New-WorkerLocalAccount @accountParameters

    Install-WorkerPowerShell -PowerShellVersion $PowerShellVersion -PowerShellMsiUrl $PowerShellMsiUrl `
        -PowerShellExecutablePath $PowerShellExecutablePath
    Install-WorkerToolIfChanged -ToolSourcePath $ToolSourcePath `
        -ToolDestinationPath 'C:\Tools\OrchestratorSpike\Convert-Extract.ps1' `
        -ComputerName $env:COMPUTERNAME -AccountName $SvcAzAutoAccountName
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WorkerSetup @PSBoundParameters
}
