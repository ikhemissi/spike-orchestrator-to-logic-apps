Set-Item -Path Function:\global:Get-LocalUser -Value { }
Set-Item -Path Function:\global:New-LocalUser -Value { }
Set-Item -Path Function:\global:Get-AuthenticodeSignature -Value { }

BeforeAll {
    $script:testPassword = [System.Security.SecureString]::new()
    $script:nasScriptPath = Join-Path $PSScriptRoot '..\setup-nas.ps1'
    $script:workerScriptPath = Join-Path $PSScriptRoot '..\setup-worker.ps1'

    . $script:nasScriptPath -SvcLaPassword $script:testPassword -SvcAzAutoPassword $script:testPassword `
        -SmbRemoteAddresses @('10.10.1.0/26')
    . $script:workerScriptPath -SvcAzAutoPassword $script:testPassword `
        -GpgPublicKey '-----BEGIN PGP PUBLIC KEY BLOCK-----' `
        -PowerShellMsiUrl 'https://example.invalid/powershell.msi' `
        -Gpg4winInstallerUrl 'https://example.invalid/gpg4win.exe' `
        -GpgHomeDirectory '/tmp/gnupg-test-home'
}

Describe 'NAS setup planning' {
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

    It "does not reset an existing local account's password" {
        Mock Get-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-la'; Password = $script:testPassword }
        New-NasLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 0
    }

    It 'creates a missing local account with the supplied secure password' {
        Mock Get-LocalUser { $null }
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-la'; Password = $script:testPassword }
        New-NasLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 1
    }
}

Describe 'Hybrid worker setup' {
    It 'plans the specified PowerShell and Gpg4win package releases' {
        $PowerShellVersion | Should -Be '7.4.13'
        $PowerShellMsiUrl | Should -Be 'https://example.invalid/powershell.msi'
        $Gpg4winInstallerUrl | Should -Be 'https://example.invalid/gpg4win.exe'
    }

    It "does not reset an existing mirrored worker account's password" {
        Mock Get-LocalUser { [pscustomobject]@{ Name = $Name } }
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-azauto'; Password = $script:testPassword }
        New-WorkerLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 0
    }

    It 'creates a missing worker account with the supplied secure password' {
        Mock Get-LocalUser { $null }
        Mock New-LocalUser {}

        $accountParameters = @{ AccountName = 'svc-azauto'; Password = $script:testPassword }
        New-WorkerLocalAccount @accountParameters

        Should -Invoke New-LocalUser -Times 1
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
