Describe 'deploy-logicapp.ps1' {
    BeforeAll {
        $script:testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "logicapp-test-$([guid]::NewGuid())"
        $script:projectDirectory = Join-Path $script:testRoot 'src/logicapp'
        $script:scriptDirectory = Join-Path $script:testRoot 'scripts'
        $null = New-Item -ItemType Directory -Force -Path `
            (Join-Path $script:projectDirectory 'workflows/ping'), `
            (Join-Path $script:projectDirectory '.vscode'), `
            (Join-Path $script:projectDirectory 'workflow-designtime'), `
            (Join-Path $script:projectDirectory 'tests'), `
            (Join-Path $script:projectDirectory '__azurite_data'), `
            $script:scriptDirectory

        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../deploy-logicapp.ps1') `
            -Destination (Join-Path $script:scriptDirectory 'deploy-logicapp.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../src/logicapp/.funcignore') `
            -Destination (Join-Path $script:projectDirectory '.funcignore')
        Set-Content -LiteralPath (Join-Path $script:projectDirectory 'host.json') -Value '{"version":"2.0"}'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory 'workflows/ping/workflow.json') -Value '{"definition":{}}'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory 'local.settings.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory '.vscode/settings.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory 'workflow-designtime/designer.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory 'tests/test-workflow.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory '__azurite_data/blob') -Value 'data'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory 'readme-test.md') -Value 'test'
        Set-Content -LiteralPath (Join-Path $script:projectDirectory 'Workflow.Tests.ps1') -Value 'test'

        $env:AZURE_RESOURCE_GROUP = 'rg-test'
        $env:LOGIC_APP_NAME = 'logicapp-test'
        $env:AZ_TEST_LOG = Join-Path $script:testRoot 'commands.log'
        $env:AZ_TEST_ZIP_COPY = Join-Path $script:testRoot 'deployed.zip'
    }

    BeforeEach {
        Mock az {
            $command = $args -join ' '
            Add-Content -LiteralPath $env:AZ_TEST_LOG -Value $command
            if ($args -contains 'config-zip') {
                $sourceIndex = [Array]::IndexOf($args, '--src')
                Copy-Item -LiteralPath $args[$sourceIndex + 1] -Destination $env:AZ_TEST_ZIP_COPY
            }
            if ($args.Count -ge 2 -and $args[0] -eq 'account' -and $args[1] -eq 'show') {
                '00000000-0000-0000-0000-000000000001'
            }
            $global:LASTEXITCODE = 0
        }
    }

    AfterAll {
        Remove-Item -LiteralPath $script:testRoot -Recurse -Force
        Remove-Item Env:AZURE_RESOURCE_GROUP, Env:LOGIC_APP_NAME, Env:AZ_TEST_LOG, Env:AZ_TEST_ZIP_COPY `
            -ErrorAction SilentlyContinue
    }

    It 'packages only deployable files and calls Azure in deployment order' {
        & (Join-Path $script:scriptDirectory 'deploy-logicapp.ps1')

        $commands = Get-Content -LiteralPath $env:AZ_TEST_LOG
        $commands.Count | Should -Be 4
        $commands[0] | Should -Match '^logicapp deployment source config-zip --resource-group rg-test --name logicapp-test --src '
        $commands[1] | Should -Be 'logicapp restart --resource-group rg-test --name logicapp-test'
        $commands[2] | Should -Be 'account show --query id --output tsv'
        $commands[3] | Should -Be 'rest --method get --url https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test/providers/Microsoft.Web/sites/logicapp-test/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2018-11-01'

        Add-Type -AssemblyName System.IO.Compression
        $archive = [System.IO.Compression.ZipFile]::OpenRead($env:AZ_TEST_ZIP_COPY)
        try {
            $actualFiles = @($archive.Entries | ForEach-Object FullName | Sort-Object)
        }
        finally {
            $archive.Dispose()
        }
        $actualFiles | Should -Be @('host.json', 'workflows/ping/workflow.json')
    }
}
