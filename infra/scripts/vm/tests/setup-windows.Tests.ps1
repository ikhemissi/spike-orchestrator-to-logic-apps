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
        -GpgPublicKey '-----BEGIN PGP PUBLIC KEY BLOCK-----' `
        -PowerShellMsiUrl 'https://example.invalid/powershell.msi' `
        -Gpg4winInstallerUrl 'https://example.invalid/gpg4win.exe' `
        -GpgHomeDirectory '/tmp/gnupg-test-home' `
        -GpgConfigPath '/tmp/orchestrator-spike-gpg-test.json'
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

    It 'plans the specified PowerShell and Gpg4win package releases' {
        $PowerShellVersion | Should -Be '7.4.13'
        $PowerShellMsiUrl | Should -Be 'https://example.invalid/powershell.msi'
        $Gpg4winInstallerUrl | Should -Be 'https://example.invalid/gpg4win.exe'
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

    It 'rejects unsigned packages before launching an installer' {
        Mock Invoke-WebRequest {}
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned' } }
        Mock Start-Process {}

        {
            Install-VerifiedPackage -Uri 'https://example.invalid/package.exe' -Extension '.exe' -InstallerArguments @('/S')
        } | Should -Throw

        Should -Invoke Start-Process -Times 0
    }

    It 'skips package installers when the requested worker tools are already installed' {
        Mock Get-InstalledProductVersion {
            if ($ExecutablePath -like '*pwsh.exe') {
                return '7.4.13'
            }

            return '2.4.8'
        }
        Mock Install-VerifiedPackage {}

        Install-WorkerPrerequisite -PowerShellVersion '7.4.13' -PowerShellMsiUrl 'https://example.invalid/powershell.msi' `
            -Gpg4winInstallerUrl 'https://example.invalid/gpg4win.exe' `
            -PowerShellExecutablePath 'C:\Program Files\PowerShell\7\pwsh.exe' `
            -GpgExecutablePath 'C:\Program Files (x86)\GnuPG\bin\gpg.exe'

        Should -Invoke Install-VerifiedPackage -Times 0
    }

    It 'imports an armored public key into the configured GnuPG home' {
        Mock Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        $keyParameters = @{
            GpgPublicKey = "-----BEGIN PGP PUBLIC KEY BLOCK-----`nZGF0YQ==`n-----END PGP PUBLIC KEY BLOCK-----"
            GpgExecutablePath = '/usr/bin/gpg'
            GpgHomeDirectory = '/tmp/gnupg-test-home'
        }

        Import-WorkerGpgPublicKey @keyParameters

        Should -Invoke Start-Process -Times 1
    }

    It 'gives svc-azauto Modify access to the GnuPG home' {
        $computerName = [System.Environment]::MachineName
        $permissions = @(Get-WorkerGpgHomePermissionPlan -ComputerName $computerName -AccountName 'svc-azauto')
        $workerIdentity = "$computerName\svc-azauto"
        $workerPermission = @($permissions | Where-Object IdentityName -eq $workerIdentity)

        $workerPermission.Count | Should -Be 1
        $workerPermission[0].FileSystemRights | Should -Be 'Modify'
    }

    It 'writes the GnuPG executable and home paths for runbooks' {
        $configPath = Join-Path $TestDrive 'OrchestratorSpike\gpg.json'
        Write-WorkerGpgConfiguration -GpgExecutablePath 'C:\Program Files (x86)\GnuPG\bin\gpg.exe' `
            -GpgHomeDirectory 'C:\ProgramData\GnuPG\svc-azauto' -GpgConfigPath $configPath

        $configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $configuration.gpgPath | Should -Be 'C:\Program Files (x86)\GnuPG\bin\gpg.exe'
        $configuration.homeDir | Should -Be 'C:\ProgramData\GnuPG\svc-azauto'
    }

    It 'rejects private keys instead of importing them' {
        Mock Start-Process {}
        $invalidKeyParameters = @{
            GpgPublicKey = 'not-an-armored-key'
            GpgExecutablePath = '/usr/bin/gpg'
            GpgHomeDirectory = '/tmp/gnupg-test-home'
        }

        { Import-WorkerGpgPublicKey @invalidKeyParameters } | Should -Throw

        Should -Invoke Start-Process -Times 0
    }
}
