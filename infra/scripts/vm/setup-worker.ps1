# Install the worker prerequisites and prepare its local run-as account and GnuPG keyring.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [securestring]$SvcAzAutoPassword,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GpgPublicKey,

    [string]$SvcAzAutoAccountName = 'svc-azauto',

    [string]$PowerShellVersion = '7.4.13',

    [string]$PowerShellMsiUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.13/PowerShell-7.4.13-win-x64.msi', # VERIFY: confirm the current PowerShell 7.4 patch release URL.

    [string]$Gpg4winInstallerUrl = 'https://files.gpg4win.org/gpg4win-4.4.1.exe', # VERIFY: confirm the current Gpg4win release URL.

    [string]$PowerShellExecutablePath = 'C:\Program Files\PowerShell\7\pwsh.exe',

    [string]$GpgExecutablePath = 'C:\Program Files (x86)\GnuPG\bin\gpg.exe', # VERIFY: confirm the install path for the selected Gpg4win release.

    [string]$GpgHomeDirectory = (Join-Path $env:ProgramData 'GnuPG\svc-azauto')
)

function New-WorkerLocalAccount {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AccountName,

        [Parameter(Mandatory = $true)]
        [securestring]$Password
    )

    if (Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue) {
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
        [ValidateSet('.msi', '.exe')]
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

        $process = Start-Process -FilePath $(
            if ($Extension -eq '.msi') { 'msiexec.exe' } else { $packagePath }
        ) -ArgumentList $(
            if ($Extension -eq '.msi') {
                @('/i', "`"$packagePath`"") + $InstallerArguments
            }
            else {
                $InstallerArguments
            }
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

function Install-WorkerPrerequisite {
    [CmdletBinding()]
    param(
        [string]$PowerShellVersion,
        [string]$PowerShellMsiUrl,
        [string]$Gpg4winInstallerUrl,
        [string]$PowerShellExecutablePath,
        [string]$GpgExecutablePath
    )

    $installedPowerShellVersion = Get-InstalledProductVersion -ExecutablePath $PowerShellExecutablePath
    if (-not $installedPowerShellVersion -or
        -not $installedPowerShellVersion.StartsWith($PowerShellVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        Install-VerifiedPackage -Uri $PowerShellMsiUrl -Extension '.msi' -InstallerArguments @('/quiet', '/norestart', 'ADD_PATH=1')
    }

    if (-not (Get-InstalledProductVersion -ExecutablePath $GpgExecutablePath)) {
        # VERIFY: confirm /S is the silent-install switch for the selected Gpg4win release.
        Install-VerifiedPackage -Uri $Gpg4winInstallerUrl -Extension '.exe' -InstallerArguments @('/S')
    }

    $finalPowerShellVersion = Get-InstalledProductVersion -ExecutablePath $PowerShellExecutablePath
    if (-not $finalPowerShellVersion -or
        -not $finalPowerShellVersion.StartsWith($PowerShellVersion, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PowerShell $PowerShellVersion was not found at the configured executable path after installation."
    }

    if (-not (Get-InstalledProductVersion -ExecutablePath $GpgExecutablePath)) {
        throw 'GnuPG was not found at the configured executable path after installation.'
    }
}

function Get-WorkerAccessRule {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Security.Principal.IdentityReference]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$Rights
    )

    $inheritanceFlags = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    return [System.Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        [System.Security.AccessControl.FileSystemRights]$Rights,
        $inheritanceFlags,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
    )
}

function Set-WorkerGpgHomePermission {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GpgHomeDirectory,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$AccountName
    )

    if (-not $PSCmdlet.ShouldProcess($GpgHomeDirectory, 'Set GnuPG home permissions')) {
        return
    }

    New-Item -Path $GpgHomeDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $acl = Get-Acl -LiteralPath $GpgHomeDirectory
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($accessRule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($accessRule)
    }

    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $workerIdentity = [System.Security.Principal.NTAccount]::new("$ComputerName\$AccountName")
    [void]$acl.AddAccessRule((Get-WorkerAccessRule -Identity $administratorsSid -Rights 'FullControl'))
    [void]$acl.AddAccessRule((Get-WorkerAccessRule -Identity $systemSid -Rights 'FullControl'))
    [void]$acl.AddAccessRule((Get-WorkerAccessRule -Identity $workerIdentity -Rights 'Modify'))
    Set-Acl -LiteralPath $GpgHomeDirectory -AclObject $acl
}

function Import-WorkerGpgPublicKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$GpgPublicKey,

        [Parameter(Mandatory = $true)]
        [string]$GpgExecutablePath,

        [Parameter(Mandatory = $true)]
        [string]$GpgHomeDirectory
    )

    if ($GpgPublicKey -notmatch '-----BEGIN PGP PUBLIC KEY BLOCK-----' -or
        $GpgPublicKey -match '-----BEGIN PGP PRIVATE KEY BLOCK-----') {
        throw 'GpgPublicKey must contain an ASCII-armored public key and no private key.'
    }

    $keyFilePath = Join-Path ([System.IO.Path]::GetTempPath()) "$([guid]::NewGuid().ToString()).asc"
    try {
        [System.IO.File]::WriteAllText($keyFilePath, $GpgPublicKey, [System.Text.Encoding]::ASCII)
        $process = Start-Process -FilePath $GpgExecutablePath -ArgumentList @(
            '--homedir', "`"$GpgHomeDirectory`"", '--batch', '--import', "`"$keyFilePath`""
        ) -Wait -PassThru -NoNewWindow

        if ($process.ExitCode -ne 0) {
            throw "GnuPG could not import the configured public key (exit code $($process.ExitCode))."
        }
    }
    finally {
        Remove-Item -LiteralPath $keyFilePath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WorkerSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SvcAzAutoPassword,

        [Parameter(Mandatory = $true)]
        [string]$GpgPublicKey,

        [string]$SvcAzAutoAccountName = 'svc-azauto',
        [string]$PowerShellVersion = '7.4.13',
        [string]$PowerShellMsiUrl = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.13/PowerShell-7.4.13-win-x64.msi',
        [string]$Gpg4winInstallerUrl = 'https://files.gpg4win.org/gpg4win-4.4.1.exe',
        [string]$PowerShellExecutablePath = 'C:\Program Files\PowerShell\7\pwsh.exe',
        [string]$GpgExecutablePath = 'C:\Program Files (x86)\GnuPG\bin\gpg.exe',
        [string]$GpgHomeDirectory = (Join-Path $env:ProgramData 'GnuPG\svc-azauto')
    )

    $accountParameters = @{ AccountName = $SvcAzAutoAccountName; Password = $SvcAzAutoPassword }
    New-WorkerLocalAccount @accountParameters
    Install-WorkerPrerequisite -PowerShellVersion $PowerShellVersion -PowerShellMsiUrl $PowerShellMsiUrl `
        -Gpg4winInstallerUrl $Gpg4winInstallerUrl -PowerShellExecutablePath $PowerShellExecutablePath `
        -GpgExecutablePath $GpgExecutablePath

    Set-WorkerGpgHomePermission -GpgHomeDirectory $GpgHomeDirectory -ComputerName $env:COMPUTERNAME -AccountName $SvcAzAutoAccountName
    # GNUPGHOME points run-as jobs at a keyring readable only by the mirrored worker account and administrators.
    [System.Environment]::SetEnvironmentVariable('GNUPGHOME', $GpgHomeDirectory, 'Machine')
    $env:GNUPGHOME = $GpgHomeDirectory
    Import-WorkerGpgPublicKey -GpgPublicKey $GpgPublicKey -GpgExecutablePath $GpgExecutablePath -GpgHomeDirectory $GpgHomeDirectory
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WorkerSetup @PSBoundParameters
}
