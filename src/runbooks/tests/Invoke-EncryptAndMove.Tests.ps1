# Exercise the runbook against an isolated GPG keyring and temporary files.
Describe 'Invoke-EncryptAndMove' {
BeforeAll {
    $script:runbook = Join-Path $PSScriptRoot '..' 'Invoke-EncryptAndMove.ps1'
    $script:originalGpgHome = $env:GNUPGHOME
    $gpgHome = Join-Path ([System.IO.Path]::GetTempPath()) "runbook-gpg-$([guid]::NewGuid().ToString('N'))"
    [void](New-Item -ItemType Directory -Path $gpgHome)
    if (-not $IsWindows) {
        & chmod 700 $gpgHome
    }
    $env:GNUPGHOME = $gpgHome
    $recipient = 'Runbook Test <runbook-test@example.invalid>'
    & gpg --batch --pinentry-mode loopback --passphrase '' --quick-generate-key $recipient default default 1d 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to generate the temporary GPG key.'
    }
}

AfterAll {
    if (Get-Command gpgconf -ErrorAction SilentlyContinue) {
        & gpgconf --kill all 2>&1 | Out-Null
    }
    $env:GNUPGHOME = $originalGpgHome
    Remove-Item -LiteralPath $gpgHome -Recurse -Force -ErrorAction SilentlyContinue
}

BeforeEach {
    $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $source = Join-Path $root 'source'
    $target = Join-Path $root 'target'
    $archive = Join-Path $root 'archive'
    foreach ($directory in @($source, $target, $archive)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $script:parameters = @{
        CorrelationId = 'test-correlation'
        SourcePath = $source
        TargetPath = $target
        ArchivePath = $archive
        Recipient = $recipient
    }
}

    It 'encrypts, archives and decrypts the source with the temporary key' {
        $sourceFile = Join-Path $source 'hello.txt'
        Set-Content -LiteralPath $sourceFile -Value 'hello from the runbook' -NoNewline
        $hash = (Get-FileHash -LiteralPath $sourceFile).Hash

        $output = @(& $runbook @parameters)
        $result = $output[0] | ConvertFrom-Json

        $output.Count | Should -Be 1
        $result.correlationId | Should -Be 'test-correlation'
        $result.status | Should -Be 'Succeeded'
        $result.filesProcessed | Should -Be 1
        $result.items[0].result | Should -Be 'encrypted'
        $result.items[0].sha256 | Should -Be $hash
        (Get-Content -Raw -LiteralPath (Join-Path $target 'hello.txt.gpg.sha256')) | Should -Be $hash
        @(Get-ChildItem -LiteralPath $archive -Filter '*_hello.txt').Count | Should -Be 1
        Test-Path -LiteralPath $sourceFile | Should -BeFalse
        $decrypted = & gpg --batch --quiet --decrypt (Join-Path $target 'hello.txt.gpg') 2>&1
        $LASTEXITCODE | Should -Be 0
        $decrypted | Should -Be 'hello from the runbook'
    }

    It 'skips an existing target with the same sidecar hash and archives the source' {
        $sourceFile = Join-Path $source 'repeat.txt'
        Set-Content -LiteralPath $sourceFile -Value 'same content' -NoNewline
        $null = & $runbook @parameters
        $encryptedFile = Join-Path $target 'repeat.txt.gpg'
        $encryptedHash = (Get-FileHash -LiteralPath $encryptedFile).Hash
        # Avoid an archive collision when the two runs occur in the same second.
        Get-ChildItem -LiteralPath $archive | Remove-Item
        Set-Content -LiteralPath $sourceFile -Value 'same content' -NoNewline

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.filesSkipped | Should -Be 1
        $result.filesProcessed | Should -Be 0
        $result.items[0].result | Should -Be 'skipped'
        (Get-FileHash -LiteralPath $encryptedFile).Hash | Should -Be $encryptedHash
        @(Get-ChildItem -LiteralPath $archive).Count | Should -Be 1
    }

    It 'processes other files when a filename contains FAIL' {
        Set-Content -LiteralPath (Join-Path $source 'a-FAIL.txt') -Value 'failure'
        Set-Content -LiteralPath (Join-Path $source 'b-ok.txt') -Value 'success'

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.status | Should -Be 'PartialFailure'
        $result.filesFailed | Should -Be 1
        $result.filesProcessed | Should -Be 1
        $result.errors[0].code | Should -Be 'SIMULATED_FAILURE'
        $result.errors[0].file | Should -Be 'a-FAIL.txt'
        $result.items[0].result | Should -Be 'failed'
        Test-Path -LiteralPath (Join-Path $source 'a-FAIL.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'b-ok.txt.gpg') | Should -BeTrue
    }

    It 'reports every file as failed when SimulateFailure is set' {
        Set-Content -LiteralPath (Join-Path $source 'one.txt') -Value 'one'
        Set-Content -LiteralPath (Join-Path $source 'two.txt') -Value 'two'

        $result = & $runbook @parameters -SimulateFailure | ConvertFrom-Json

        $result.status | Should -Be 'PartialFailure'
        $result.filesFailed | Should -Be 2
        $result.filesProcessed | Should -Be 0
        @($result.errors | Where-Object code -eq 'SIMULATED_FAILURE').Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $source).Count | Should -Be 2
    }

    It 'throws when the source directory is missing' {
        $parameters.SourcePath = Join-Path $root 'missing'
        { & $runbook @parameters } | Should -Throw
    }

    It 'processes only MaxFiles in name order' {
        foreach ($name in @('c.txt', 'a.txt', 'b.txt')) {
            Set-Content -LiteralPath (Join-Path $source $name) -Value $name
        }

        $result = & $runbook @parameters -MaxFiles 2 | ConvertFrom-Json

        $result.filesProcessed | Should -Be 2
        @($result.items.name) | Should -Be @('a.txt', 'b.txt')
        Test-Path -LiteralPath (Join-Path $source 'c.txt') | Should -BeTrue
    }

    It 'processes hidden source files' {
        $hiddenFile = Join-Path $source '.hidden.txt'
        Set-Content -LiteralPath $hiddenFile -Value 'hidden'
        if ($IsWindows) {
            (Get-Item -LiteralPath $hiddenFile -Force).Attributes = [System.IO.FileAttributes]::Hidden
        }

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.filesProcessed | Should -Be 1
        Test-Path -LiteralPath (Join-Path $target '.hidden.txt.gpg') | Should -BeTrue
    }

    It 'accepts paths relative to the PowerShell location' {
        Set-Content -LiteralPath (Join-Path $source 'file.txt') -Value 'content'
        Push-Location $root
        try {
            $parameters.SourcePath = 'source'
            $parameters.TargetPath = 'target'
            $parameters.ArchivePath = 'archive'

            $result = & $runbook @parameters | ConvertFrom-Json
        }
        finally {
            Pop-Location
        }

        $result.filesProcessed | Should -Be 1
        Test-Path -LiteralPath (Join-Path $target 'file.txt.gpg') | Should -BeTrue
    }

    It 'emits one compressed JSON line with identity and worker under 1 MiB' {
        Set-Content -LiteralPath (Join-Path $source 'file.txt') -Value 'content'

        $output = @(& $runbook @parameters -Verbose)
        $result = $output[0] | ConvertFrom-Json

        $output.Count | Should -Be 1
        $output[0] | Should -Not -Match '[\r\n]'
        [System.Text.Encoding]::UTF8.GetByteCount($output[0]) | Should -BeLessThan 1MB
        $result.runAs | Should -Not -BeNullOrEmpty
        $result.worker | Should -Not -BeNullOrEmpty
        $result.startedAt | Should -Not -BeNullOrEmpty
        $result.completedAt | Should -Not -BeNullOrEmpty
    }

    It 're-encrypts when the source hash differs from the sidecar' {
        $sourceFile = Join-Path $source 'changed.txt'
        Set-Content -LiteralPath $sourceFile -Value 'old' -NoNewline
        $null = & $runbook @parameters
        Get-ChildItem -LiteralPath $archive | Remove-Item
        Set-Content -LiteralPath $sourceFile -Value 'new' -NoNewline

        $result = & $runbook @parameters | ConvertFrom-Json

        $result.filesProcessed | Should -Be 1
        $result.filesSkipped | Should -Be 0
        $decrypted = & gpg --batch --quiet --decrypt (Join-Path $target 'changed.txt.gpg') 2>&1
        $decrypted | Should -Be 'new'
    }

    It 'throws and preserves the source when encryption fails' {
        Set-Content -LiteralPath (Join-Path $source 'file.txt') -Value 'content'
        $parameters.Recipient = 'missing-recipient@example.invalid'

        { & $runbook @parameters } | Should -Throw

        Test-Path -LiteralPath (Join-Path $source 'file.txt') | Should -BeTrue
        @(Get-ChildItem -LiteralPath $target -Force).Count | Should -Be 0
    }

    It 'does not leave a stale sidecar if writing the replacement sidecar fails' {
        $sourceFile = Join-Path $source 'changed.txt'
        Set-Content -LiteralPath $sourceFile -Value 'old' -NoNewline
        $null = & $runbook @parameters
        Set-Content -LiteralPath $sourceFile -Value 'new' -NoNewline
        Mock Set-Content { throw 'Sidecar write failed' } -ParameterFilter { $LiteralPath -like '*.sha256' }

        { & $runbook @parameters } | Should -Throw

        Test-Path -LiteralPath (Join-Path $target 'changed.txt.gpg.sha256') | Should -BeFalse
        Test-Path -LiteralPath $sourceFile | Should -BeTrue
    }
}
