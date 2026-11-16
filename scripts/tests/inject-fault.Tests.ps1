BeforeAll {
    . (Join-Path $PSScriptRoot '../inject-fault.ps1')
    $script:AzCalls = [Collections.Generic.List[object]]::new()
    $script:PartnerRule = [PSCustomObject]@{
        name = 'partner-allow'
        sourceAddressPrefixes = @('198.51.100.10', '203.0.113.8')
        description = 'partner allow list'
    }

    Mock Invoke-AzCli {
        $script:AzCalls.Add(@($Arguments))
        if ($Arguments[0..3] -join ' ' -eq 'network nsg rule list') {
            if ($Arguments -contains 'servers-nsg') {
                return '[]'
            }
            return @($script:PartnerRule) | ConvertTo-Json -Compress
        }
        if ($Arguments[0..1] -join ' ' -eq 'logicapp show') {
            return '/subscriptions/test/resourceGroups/test/providers/Microsoft.Network/virtualNetworks/vnet/subnets/logicapp'
        }
        if ($Arguments[0..3] -join ' ' -eq 'network vnet subnet show') {
            return '10.10.0.0/27'
        }
        if ($Arguments[0..2] -join ' ' -eq 'vm list-ip-addresses') {
            return '10.20.0.4'
        }
        if ($Arguments[0..3] -join ' ' -eq 'network nsg rule update') {
            $start = [Array]::IndexOf($Arguments, '--source-address-prefixes') + 1
            $end = [Array]::IndexOf($Arguments, '--description')
            $script:PartnerRule.sourceAddressPrefixes = @($Arguments[$start..($end - 1)])
            $script:PartnerRule.description = $Arguments[$end + 1]
        }
        return ''
    }
}

Describe 'inject-fault partner-ip-block' {
    BeforeEach {
        $env:AZURE_RESOURCE_GROUP = 'test-rg'
        $env:AZURE_SUBSCRIPTION_ID = '00000000-0000-0000-0000-000000000000'
        $env:PARTNER_NSG_NAME = 'partner-nsg'
        $env:NAT_PUBLIC_IP = '198.51.100.10'
        $script:PartnerRule.sourceAddressPrefixes = @('198.51.100.10', '203.0.113.8')
        $script:PartnerRule.description = 'partner allow list'
        $script:AzCalls.Clear()
    }

    It 'removes exactly the NAT IP from the rule and restore-all data puts it back' {
        Invoke-PartnerIpBlock

        $script:PartnerRule.sourceAddressPrefixes | Should -Be @('203.0.113.8')
        $script:PartnerRule.description | Should -Match '^copilot-restore:'

        Restore-PartnerIpBlock

        $script:PartnerRule.sourceAddressPrefixes | Should -Be @('198.51.100.10', '203.0.113.8')
        $script:PartnerRule.description | Should -Be 'partner allow list'
        $script:AzCalls.Count | Should -Be 4
    }

    It 'scopes the NAS block to the Logic App subnet and NAS address on TCP 445' {
        $env:LOGIC_APP_NAME = 'logicapp-test'
        $env:NAS_VM_NAME = 'nas-test'
        $env:SERVERS_NSG_NAME = 'servers-nsg'

        Invoke-NasBlock

        $call = $script:AzCalls | Where-Object { $_ -contains 'copilot-nas-block' } | Select-Object -Last 1
        $call | Should -Contain '10.10.0.0/27'
        $call | Should -Contain '10.20.0.4/32'
        $call | Should -Contain '445'
    }
}
