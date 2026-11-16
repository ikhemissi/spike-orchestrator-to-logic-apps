BeforeAll {
    . (Join-Path $PSScriptRoot '../lib/Workflows.ps1')
    . (Join-Path $PSScriptRoot '../lib/Files.ps1')
}

Describe 'Partner file helpers' {
    It 'lists FTP or SFTP files through curl' {
        Mock Invoke-CurlCommand { return @('one.csv', 'two.csv') }

        $files = Get-PartnerFile -Url 'ftp://partner.example/outbound/'

        $files | Should -Be @('one.csv', 'two.csv')
        Should -Invoke Invoke-CurlCommand -Times 1 -ParameterFilter {
            $Arguments -contains '--list-only' -and $Arguments -contains '--ftp-pasv'
        }
    }

    It 'does not pass the FTP passive-mode option to SFTP' {
        Mock Invoke-CurlCommand { return @('one.csv') }

        Get-PartnerFile -Url 'sftp://partner.example/outbound/' | Should -Be 'one.csv'

        Should -Invoke Invoke-CurlCommand -Times 1 -ParameterFilter {
            $Arguments -contains '--list-only' -and $Arguments -notcontains '--ftp-pasv'
        }
    }
}
