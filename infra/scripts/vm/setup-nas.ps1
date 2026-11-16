# Configure the simulated NAS share, its local users, and SMB access.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [securestring]$SvcLaPassword,

    [Parameter(Mandatory = $true)]
    [ValidateNotNull()]
    [securestring]$SvcAzAutoPassword,

    [string]$SvcLaAccountName = 'svc-la',

    [string]$SvcAzAutoAccountName = 'svc-azauto',

    [string]$ShareRoot = 'C:\share',

    [string]$ShareName = 'share',

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]]$SmbRemoteAddresses,

    [string]$FirewallRuleName = 'Spike-SMB-In'
)

function Get-NasDirectoryPlan {
    return @(
        '.',
        'j3',
        'j3\in',
        'j3\out',
        'j3\archive',
        'j4',
        'j4\finance',
        'j4\documents',
        'j4\integration',
        'j4\quarantine',
        'folderwatch',
        'folderwatch\in',
        'folderwatch\processed'
    )
}

function Get-NasPermissionPlan {
    [CmdletBinding()]
    param(
        [string]$SvcLaAccountName = 'svc-la',
        [string]$SvcAzAutoAccountName = 'svc-azauto'
    )

    # Read-only access on the share root and job directories allows navigation without granting access to unrelated job data.
    $permissions = @(
        [pscustomobject]@{ RelativePath = '.'; AccountName = $SvcLaAccountName; FileSystemRights = 'ReadAndExecute' },
        [pscustomobject]@{ RelativePath = '.'; AccountName = $SvcAzAutoAccountName; FileSystemRights = 'ReadAndExecute' },
        [pscustomobject]@{ RelativePath = 'j3'; AccountName = $SvcAzAutoAccountName; FileSystemRights = 'ReadAndExecute' },
        [pscustomobject]@{ RelativePath = 'j4'; AccountName = $SvcLaAccountName; FileSystemRights = 'ReadAndExecute' },
        [pscustomobject]@{ RelativePath = 'folderwatch'; AccountName = $SvcLaAccountName; FileSystemRights = 'ReadAndExecute' }
    )

    # J3 encryption runs on the Hybrid Worker, so only svc-azauto can change its input, output, or archive data.
    foreach ($relativePath in @('j3\in', 'j3\out', 'j3\archive')) {
        $permissions += [pscustomobject]@{
            RelativePath = $relativePath
            AccountName = $SvcAzAutoAccountName
            FileSystemRights = 'Modify'
        }
    }

    # The Logic App File System connector handles J4 and folder monitoring; it must not modify J3 data.
    foreach ($relativePath in @('j4\finance', 'j4\documents', 'j4\integration', 'j4\quarantine', 'folderwatch\in', 'folderwatch\processed')) {
        $permissions += [pscustomobject]@{
            RelativePath = $relativePath
            AccountName = $SvcLaAccountName
            FileSystemRights = 'Modify'
        }
    }

    return $permissions
}

function New-NasLocalAccount {
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

function Get-NasAccessRule {
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

function Set-NasDirectoryPermission {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object[]]$Permissions,

        [Parameter(Mandatory = $true)]
        [string]$ComputerName
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Apply directory permissions')) {
        return
    }

    $acl = Get-Acl -LiteralPath $Path
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($accessRule in @($acl.Access)) {
        [void]$acl.RemoveAccessRuleSpecific($accessRule)
    }
    $administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $systemSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    [void]$acl.AddAccessRule((Get-NasAccessRule -Identity $administratorsSid -Rights 'FullControl' -InheritToChildren))
    [void]$acl.AddAccessRule((Get-NasAccessRule -Identity $systemSid -Rights 'FullControl' -InheritToChildren))

    foreach ($permission in $Permissions) {
        $accountIdentity = [System.Security.Principal.NTAccount]::new("$ComputerName\$($permission.AccountName)")
        $inheritToChildren = $permission.FileSystemRights -eq 'Modify'
        $ruleParameters = @{
            Identity = $accountIdentity
            Rights = $permission.FileSystemRights
        }
        if ($inheritToChildren) {
            $ruleParameters.InheritToChildren = $true
        }
        [void]$acl.AddAccessRule((Get-NasAccessRule @ruleParameters))
    }

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Set-NasSharePermission {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShareName,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedAccounts,

        [string]$AdministratorAccount = 'BUILTIN\Administrators'
    )

    if (-not $PSCmdlet.ShouldProcess($ShareName, 'Reconcile SMB share permissions')) {
        return
    }

    # Share-level Change is needed for SMB writes; the NTFS ACLs above constrain each account to its own job folders.
    $desiredAccess = @{}
    $desiredAccess[$AdministratorAccount] = 'Full'
    foreach ($accountName in $AllowedAccounts) {
        $desiredAccess[$accountName] = 'Change'
    }

    $existingAccess = @(Get-SmbShareAccess -Name $ShareName)
    foreach ($access in $existingAccess) {
        $desiredRight = $desiredAccess[$access.AccountName]
        if (-not $desiredRight -or $access.AccessControlType -ne 'Allow' -or $access.AccessRight -ne $desiredRight) {
            Revoke-SmbShareAccess -Name $ShareName -AccountName $access.AccountName -Confirm:$false
        }
    }

    $existingAccess = @(Get-SmbShareAccess -Name $ShareName)
    foreach ($accountName in $desiredAccess.Keys) {
        $desiredRight = $desiredAccess[$accountName]
        $hasDesiredAccess = @($existingAccess | Where-Object {
            $_.AccountName -ieq $accountName -and
            $_.AccessControlType -eq 'Allow' -and
            $_.AccessRight -eq $desiredRight
        }).Count -gt 0

        if (-not $hasDesiredAccess) {
            Grant-SmbShareAccess -Name $ShareName -AccountName $accountName -AccessRight $desiredRight -Confirm:$false | Out-Null
        }
    }
}

function Invoke-NasSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$SvcLaPassword,

        [Parameter(Mandatory = $true)]
        [securestring]$SvcAzAutoPassword,

        [string]$SvcLaAccountName = 'svc-la',

        [string]$SvcAzAutoAccountName = 'svc-azauto',

        [string]$ShareRoot = 'C:\share',

        [string]$ShareName = 'share',

        [Parameter(Mandatory = $true)]
        [string[]]$SmbRemoteAddresses,

        [string]$FirewallRuleName = 'Spike-SMB-In'
    )

    $svcLaParameters = @{ AccountName = $SvcLaAccountName; Password = $SvcLaPassword }
    $svcAzAutoParameters = @{ AccountName = $SvcAzAutoAccountName; Password = $SvcAzAutoPassword }
    New-NasLocalAccount @svcLaParameters
    New-NasLocalAccount @svcAzAutoParameters

    foreach ($relativePath in Get-NasDirectoryPlan) {
        $directoryPath = if ($relativePath -eq '.') { $ShareRoot } else { Join-Path $ShareRoot $relativePath }
        New-Item -Path $directoryPath -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }

    $computerName = $env:COMPUTERNAME
    $permissionPlan = Get-NasPermissionPlan -SvcLaAccountName $SvcLaAccountName -SvcAzAutoAccountName $SvcAzAutoAccountName
    foreach ($relativePath in Get-NasDirectoryPlan) {
        $directoryPath = if ($relativePath -eq '.') { $ShareRoot } else { Join-Path $ShareRoot $relativePath }
        $directoryPermissions = @($permissionPlan | Where-Object { $_.RelativePath -eq $relativePath })
        Set-NasDirectoryPermission -Path $directoryPath -Permissions $directoryPermissions -ComputerName $computerName
    }

    $share = Get-SmbShare -Name $ShareName -ErrorAction SilentlyContinue
    if ($share) {
        $existingPath = [System.IO.Path]::GetFullPath($share.Path).TrimEnd('\')
        $expectedPath = [System.IO.Path]::GetFullPath($ShareRoot).TrimEnd('\')
        if ($existingPath -ine $expectedPath) {
            throw "The SMB share '$ShareName' already points to a different directory."
        }
    }
    else {
        $shareAccounts = @("$computerName\$SvcLaAccountName", "$computerName\$SvcAzAutoAccountName")
        New-SmbShare -Name $ShareName -Path $ShareRoot -FullAccess 'BUILTIN\Administrators' -ChangeAccess $shareAccounts | Out-Null
    }

    Set-NasSharePermission -ShareName $ShareName -AllowedAccounts @(
        "$computerName\$SvcLaAccountName",
        "$computerName\$SvcAzAutoAccountName"
    )

    if (-not (Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $FirewallRuleName -DisplayName $FirewallRuleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort 445 -RemoteAddress $SmbRemoteAddresses -Profile Any -Enabled True | Out-Null
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-NasSetup @PSBoundParameters
}
