Set-Item -Path Function:\global:Get-LocalUser -Value { }
Set-Item -Path Function:\global:New-LocalUser -Value { }
Set-Item -Path Function:\global:Set-LocalUser -Value { }
Set-Item -Path Function:\global:Get-AuthenticodeSignature -Value { }
Set-Item -Path Function:\global:Get-NetFirewallRule -Value { }
Set-Item -Path Function:\global:New-NetFirewallRule -Value { }
Set-Item -Path Function:\global:Set-NetFirewallRule -Value { }

BeforeAll {
    $script:testPassword = [System.Security.SecureString]::new()
    $script:nasScriptPath = Join-Path $PSScriptRoot '..\setup-nas.ps1'
    $script:workerScriptPath = Join-Path $PSScriptRoot '..\setup-worker.ps1'

    # Custom Script Extension supplies plaintext protected settings; script binding must accept strings.
    . $script:nasScriptPath -SvcLaPassword 'nas-test-password' -SvcAzAutoPassword 'worker-test-password' `
        -SmbRemoteAddresses @('10.10.1.0/26')
    . $script:workerScriptPath -SvcAzAutoPassword 'worker-test-password' `
        -PowerShellMsiUrl 'https://example.invalid/powershell.msi'
}

Describe 'NAS setup planning' {
    It 'converts the Custom Script Extension password into a SecureString for local accounts' {
        (ConvertTo-NasSecurePassword -Password 'nas-test-password') | Should -BeOfType [securestring]
    }

    It 'plans Modify only for each job account data folders' {
        $plan = @(Get-NasPermissionPlan)
        $modifyPlan = @($plan | Where-Object FileSystemRights -eq 'Modify')

        $modifyPlan.Count | Should -Be 9
        @($modifyPlan | Where-Object { $_.RelativePath -like 'j3\*' -and $_.AccountName -ne 'svc-azauto' }).Count | Should -Be 0
        @($modifyPlan | Where-Object { $_.RelativePath -like 'j4\*' -and $_.AccountName -ne 'svc-la' }).Count | Should -Be 0
        @($modifyPlan | Where-Object { $_.RelativePath -like 'folderwatch\*' -and $_.AccountName -ne 'svc-la' }).Count | Should -Be 0
    }

    It 'creates the folderwatch processed directory' {
        Get-NasDirectoryPlan | Should -Contain 'folderwatch\processed'
    }

    It 'updates an existing local account password' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock Set-LocalUser {}
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-la'; Password = $script:testPassword }
        New-NasLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 0
        Should -Invoke Set-LocalUser -Times 1
    }

    It 'creates a missing local account with the supplied secure password' {
        Mock Get-LocalUser { $null }
        Mock Set-LocalUser {}
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-la'; Password = $script:testPassword }
        New-NasLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 1
        Should -Invoke Set-LocalUser -Times 0
    }

    It 'updates an existing SMB firewall rule remote-address scope' {
        Mock Get-NetFirewallRule { [pscustomobject]@{ Name = $Name } }
        Mock New-NetFirewallRule {}
        Mock Set-NetFirewallRule {}

        Set-NasFirewallRule -FirewallRuleName 'Spike-SMB-In' -SmbRemoteAddresses @('10.10.1.0/26')

        Should -Invoke Set-NetFirewallRule -Times 1
        Should -Invoke New-NetFirewallRule -Times 0
    }
}

Describe 'Hybrid worker setup' {
    It 'converts the Custom Script Extension password into a SecureString for the worker account' {
        (ConvertTo-WorkerSecurePassword -Password 'worker-test-password') | Should -BeOfType [securestring]
    }

    It 'defaults the worker tool source path next to the setup script' {
        $PowerShellVersion | Should -Be '7.4.13'
        $PowerShellMsiUrl | Should -Be 'https://example.invalid/powershell.msi'
        $ToolSourcePath | Should -Be '.\Convert-Extract.ps1'
    }

    It 'updates an existing mirrored worker account password' {
        Mock Get-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock Set-LocalUser {}
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-azauto'; Password = $script:testPassword }
        New-WorkerLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 0
        Should -Invoke Set-LocalUser -Times 1
    }

    It 'creates a missing worker account with the supplied secure password' {
        Mock Get-LocalUser { $null }
        Mock Set-LocalUser {}
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-azauto'; Password = $script:testPassword }
        New-WorkerLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 1
        Should -Invoke Set-LocalUser -Times 0
    }

    It 'rejects unsigned PowerShell MSI packages before launching an installer' {
        Mock Invoke-WebRequest {}
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned' } }
        Mock Start-Process {}

        {
            Install-VerifiedPackage -Uri 'https://example.invalid/package.msi' -Extension '.msi' -InstallerArguments @('/quiet')
        } | Should -Throw

        Should -Invoke Start-Process -Times 0
    }

    It 'skips the PowerShell installer when the requested version is already installed' {
        Mock Get-InstalledProductVersion { '7.4.13' }
        Mock Install-VerifiedPackage {}

        Install-WorkerPowerShell -PowerShellVersion '7.4.13' -PowerShellMsiUrl 'https://example.invalid/powershell.msi' `
            -PowerShellExecutablePath 'C:\Program Files\PowerShell\7\pwsh.exe'

        Should -Invoke Install-VerifiedPackage -Times 0
    }

    It 'grants the local tool only to Administrators and svc-azauto' {
        $computerName = [System.Environment]::MachineName
        $permissions = @(Get-WorkerToolPermissionPlan -ComputerName $computerName -AccountName 'svc-azauto')
        $workerIdentity = "$computerName\svc-azauto"
        $workerPermission = @($permissions | Where-Object IdentityName -eq $workerIdentity)
        $administratorPermission = @($permissions | Where-Object IdentityName -eq 'BUILTIN\Administrators')

        $permissions.Count | Should -Be 2
        $workerPermission.Count | Should -Be 1
        $workerPermission[0].FileSystemRights | Should -Be 'ReadAndExecute'
        $administratorPermission.Count | Should -Be 1
        $administratorPermission[0].FileSystemRights | Should -Be 'FullControl'
    }

    It 'copies the local tool only when its content changes' {
        $sourcePath = Join-Path $TestDrive 'Convert-Extract.ps1'
        $destinationDirectory = Join-Path $TestDrive 'Tools\OrchestratorSpike'
        $destinationPath = Join-Path $destinationDirectory 'Convert-Extract.ps1'
        Set-Content -LiteralPath $sourcePath -Value 'Write-Output "conversion tool"' -NoNewline
        Mock Set-WorkerToolPermission {}

        Install-WorkerToolIfChanged -ToolSourcePath $sourcePath -ToolDestinationPath $destinationPath `
            -ComputerName ([System.Environment]::MachineName) -AccountName 'svc-azauto'

        (Get-Content -LiteralPath $destinationPath -Raw) | Should -Be 'Write-Output "conversion tool"'
        Should -Invoke Set-WorkerToolPermission -Times 2

        Mock Copy-Item {}
        Install-WorkerToolIfChanged -ToolSourcePath $sourcePath -ToolDestinationPath $destinationPath `
            -ComputerName ([System.Environment]::MachineName) -AccountName 'svc-azauto'

        Should -Invoke Copy-Item -Times 0
    }

    It 'replaces the installed local tool when its content changes' {
        $sourcePath = Join-Path $TestDrive 'updated-Convert-Extract.ps1'
        $destinationDirectory = Join-Path $TestDrive 'UpdatedTools\OrchestratorSpike'
        $destinationPath = Join-Path $destinationDirectory 'Convert-Extract.ps1'
        Set-Content -LiteralPath $sourcePath -Value 'Write-Output "updated conversion tool"' -NoNewline
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null
        Set-Content -LiteralPath $destinationPath -Value 'Write-Output "old conversion tool"' -NoNewline
        Mock Set-WorkerToolPermission {}

        Install-WorkerToolIfChanged -ToolSourcePath $sourcePath -ToolDestinationPath $destinationPath `
            -ComputerName ([System.Environment]::MachineName) -AccountName 'svc-azauto'

        (Get-Content -LiteralPath $destinationPath -Raw) | Should -Be 'Write-Output "updated conversion tool"'
    }
}
