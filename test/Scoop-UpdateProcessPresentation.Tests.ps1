BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\update-processes.ps1"
    . "$PSScriptRoot\..\lib\fixed-path-processes.ps1"
    . "$PSScriptRoot\..\lib\update-process-presentation.ps1"
}

Describe 'Stop-ScoopAppForUpdate' -Tag 'Scoop' {
    BeforeEach {
        $script:target = [PSCustomObject]@{
            App    = 'jackett'
            Global = $false
        }
        $script:expectedState = [PSCustomObject]@{
            App                = 'jackett'
            Global             = $false
            Processes          = @()
            RestartExecutables = @()
        }

        Mock Test-ScoopProcessesIncludeService { $false }
        Mock New-ScoopAppUpdateProcessState { $script:expectedState }
        Mock Stop-Process { }
        Mock Start-Sleep { }
        Mock Start-ScoopAppAfterUpdate { }
        Mock warn { }
    }

    It 'stops replacement processes that appear during shutdown' {
        $script:processLookupCount = 0
        Mock Get-ScoopAppRunningProcesses {
            $script:processLookupCount++
            switch ($script:processLookupCount) {
                1 { @([PSCustomObject]@{ Id = 101; ProcessName = 'JackettTray' }) }
                2 { @([PSCustomObject]@{ Id = 202; ProcessName = 'JackettConsole' }) }
                default { @() }
            }
        }

        $result = Stop-ScoopAppForUpdate -Target $script:target

        $result.App | Should -Be 'jackett'
        Should -Invoke Stop-Process -Times 2 -Exactly
        Should -Invoke Start-ScoopAppAfterUpdate -Times 0 -Exactly
        Should -Invoke warn -Times 0 -Exactly
    }

    It 'restores the app after the bounded retry window expires' {
        Mock Get-ScoopAppRunningProcesses {
            @([PSCustomObject]@{ Id = 303; ProcessName = 'JackettTray' })
        }

        $result = Stop-ScoopAppForUpdate -Target $script:target

        $result | Should -BeNullOrEmpty
        Should -Invoke Stop-Process -Times 50 -Exactly
        Should -Invoke Start-ScoopAppAfterUpdate -Times 1 -Exactly
        Should -Invoke warn -Times 1 -Exactly
    }
}
