BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/Workflows.ps1')
    . (Join-Path $PSScriptRoot '../lib/Files.ps1')
}

Describe 'Partner file helpers' {
    It 'lists FTP or SFTP files through curl' {
        Mock Invoke-CurlCommand { return @('one.csv', 'two.csv') }

        $files = Get-PartnerFile -Url 'ftp://partner.example:2121/outbound/'

        $files | Should -Be @('one.csv', 'two.csv')
        Should -Invoke Invoke-CurlCommand -Times 1 -ParameterFilter {
            $Arguments -contains '--list-only' -and $Arguments -contains '--ftp-pasv' -and
            $Arguments[-1] -eq 'ftp://partner.example:2121/outbound/'
        }
    }

    It 'does not pass the FTP passive-mode option to SFTP' {
        Mock Invoke-CurlCommand { return @('one.csv') }

        Get-PartnerFile -Url 'sftp://partner.example:2222/outbound/' | Should -Be 'one.csv'

        Should -Invoke Invoke-CurlCommand -Times 1 -ParameterFilter {
            $Arguments -contains '--list-only' -and $Arguments -notcontains '--ftp-pasv' -and
            $Arguments[-1] -eq 'sftp://partner.example:2222/outbound/'
        }
    }

    It 'signs in to SFTP with a private key when one is given' {
        Mock Invoke-CurlCommand { return @() }

        Get-PartnerFile -Url 'sftp://partner.example:2222/outbound/' -UserName 'partner-b' -PrivateKeyPath '/keys/partner-b' | Out-Null

        Should -Invoke Invoke-CurlCommand -Times 1 -ParameterFilter {
            ($Arguments -join ' ') -match '--user partner-b: --key /keys/partner-b'
        }
    }

    It 'deletes an FTP file with DELE against its parent folder' {
        Mock Invoke-CurlCommand { return @() }

        Remove-PartnerFile -Url 'ftp://partner.example:2121/outbound/old%20file.csv' -Confirm:$false

        Should -Invoke Invoke-CurlCommand -Times 1 -ParameterFilter {
            $Arguments[-1] -eq 'ftp://partner.example:2121/outbound/' -and
            $Arguments -contains 'DELE /outbound/old file.csv'
        }
    }

    It 'deletes an SFTP file with rm against its parent folder' {
        Mock Invoke-CurlCommand { return @() }

        Remove-PartnerFile -Url 'sftp://partner.example:2222/outbound/old.csv' -Confirm:$false

        Should -Invoke Invoke-CurlCommand -Times 1 -ParameterFilter {
            $Arguments[-1] -eq 'sftp://partner.example:2222/outbound/' -and $Arguments -contains 'rm /outbound/old.csv'
        }
    }
}

Describe 'Partner password handling' {
    It 'passes an FTP password to curl on stdin, never on the command line' {
        Mock Invoke-ExternalCommand { 'one.csv' }
        $password = [Security.SecureString]::new()
        foreach ($character in 'p@ss"word'.ToCharArray()) {
            $password.AppendChar($character)
        }
        $credential = [System.Management.Automation.PSCredential]::new('partner-a', $password)

        Get-PartnerFile -Url 'ftp://partner.example:2121/outbound/' -Credential $credential | Should -Be 'one.csv'

        Should -Invoke Invoke-ExternalCommand -Times 1 -ParameterFilter {
            $Name -eq 'curl' -and
            ($Arguments -join ' ') -notmatch 'p@ss' -and
            ($Arguments -join ' ') -match '^--config - ' -and
            $Arguments[-1] -eq 'ftp://partner.example:2121/outbound/' -and
            $InputText -eq 'user = "partner-a:p@ss\"word"'
        }
    }
}

Describe 'NAS file helpers' {
    It 'lists NAS files with a PowerShell Run Command, since the NAS VM runs Windows' {
        $nasEnvironment = @{ AZURE_RESOURCE_GROUP = 'rg-test'; NAS_VM_NAME = 'vm-nas01' }
        $encodedNames = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("a.csv`nb.csv"))
        Mock Invoke-AzCommand { ConvertTo-Json @{ value = @(@{ message = "RESULT:$encodedNames" }) } -Depth 5 }

        $files = Get-NasFile -Environment $nasEnvironment -Path 'D:\share\j4\finance'

        $files | Should -Be @('a.csv', 'b.csv')
        Should -Invoke Invoke-AzCommand -Times 1 -ParameterFilter {
            $Arguments -contains 'RunPowerShellScript' -and $Arguments -contains 'Path=D:\share\j4\finance'
        }
    }

    It 'writes NAS file content as base64 and checks the confirmation' {
        $nasEnvironment = @{ AZURE_RESOURCE_GROUP = 'rg-test'; NAS_VM_NAME = 'vm-nas01' }
        Mock Invoke-AzCommand { ConvertTo-Json @{ value = @(@{ message = 'RESULT:written' }) } -Depth 5 }

        Write-NasFile -Environment $nasEnvironment -Path 'D:\share\in.csv' -Content ([Text.Encoding]::UTF8.GetBytes('id'))

        Should -Invoke Invoke-AzCommand -Times 1 -ParameterFilter { $Arguments -contains 'ContentBase64=aWQ=' }
    }
}
