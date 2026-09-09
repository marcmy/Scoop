BeforeAll {
    . "$PSScriptRoot\Scoop-TestLib.ps1"
    . "$PSScriptRoot\..\lib\core.ps1"
    . "$PSScriptRoot\..\lib\fixed-path.ps1"
    . "$PSScriptRoot\..\lib\update-processes.ps1"
    . "$PSScriptRoot\..\lib\fixed-path-processes.ps1"
    . "$PSScriptRoot\..\lib\update-process-presentation.ps1"
}

Describe 'Elevated managed app process detection' -Tag 'Scoop' {
    BeforeEach {
        $script:fixedRoot = 'C:\Users\tester\scoop\fixed\islc'
        $script:oldFixedRoot = 'C:\Users\tester\scoop\fixed\islc.old'
        $script:islcExecutable = "$script:oldFixedRoot\Intelligent standby list cleaner ISLC.exe"
    }

    It 'falls back to the native limited-rights query when Get-Process hides Path' {
        $process = [PSCustomObject]@{
            Id               = 22088
            ProcessName      = 'Intelligent standby list cleaner ISLC'
            Path             = $null
            MainWindowHandle = 1
        }

        Mock Get-ScoopNativeProcessExecutablePath { $script:islcExecutable }

        Get-ScoopAppProcessExecutablePath -Process $process | Should -Be $script:islcExecutable
        Should -Invoke Get-ScoopNativeProcessExecutablePath -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 22088 }
    }

    It 'prefers a readable process path without invoking the native fallback' {
        $process = [PSCustomObject]@{
            Id               = 22088
            ProcessName      = 'Intelligent standby list cleaner ISLC'
            Path             = 'C:\Other\Intelligent standby list cleaner ISLC.exe'
            MainWindowHandle = 1
        }

        Mock Get-ScoopNativeProcessExecutablePath { throw 'should not be called' }

        Get-ScoopAppProcessExecutablePath -Process $process | Should -Be $process.Path
        Should -Invoke Get-ScoopNativeProcessExecutablePath -Times 0 -Exactly
    }

    It 'recognizes a process still running from the previous fixed-path tree' {
        $process = [PSCustomObject]@{
            Id               = 22088
            ProcessName      = 'Intelligent standby list cleaner ISLC'
            Path             = $null
            MainWindowHandle = 1
        }

        Mock appdir { 'C:\Users\tester\scoop\apps\islc' }
        Mock fixedpathdir { $script:fixedRoot }
        Mock Get-ScoopNativeProcessExecutablePath { $script:islcExecutable }
        Mock Get-Process { @($process) }

        $result = @(Get-ScoopAppRunningProcesses -App 'islc' -Global $false)

        $result.Count | Should -Be 1
        $result[0].Id | Should -Be 22088
    }

    It 'maps a previous fixed-path executable back to its app-relative restart path' {
        Mock fixedpathdir { $script:fixedRoot }

        $relativePath = Get-ScoopAppRelativeExecutablePath -App 'islc' -Global $false -ExecutablePath $script:islcExecutable

        $relativePath | Should -Be 'Intelligent standby list cleaner ISLC.exe'
    }
}

Describe 'Windows service process safety check' -Tag 'Scoop' {
    BeforeEach {
        Mock warn { }
    }

    It 'uses CIM when service information is available' {
        Mock Get-CimInstance {
            @([PSCustomObject]@{ ProcessId = 101 })
        }
        Mock Get-ScoopNativeServiceProcessId { throw 'native fallback should not be called' }

        Test-ScoopProcessesIncludeService -Processes @([PSCustomObject]@{ Id = 101 }) | Should -BeTrue
        Should -Invoke Get-ScoopNativeServiceProcessId -Times 0 -Exactly
        Should -Invoke warn -Times 0 -Exactly
    }

    It 'uses native SCM enumeration when CIM access is denied' {
        Mock Get-CimInstance { throw 'Access denied' }
        Mock Get-ScoopNativeServiceProcessId { @(4564, 8936) }

        Test-ScoopProcessesIncludeService -Processes @([PSCustomObject]@{ Id = 22088 }) | Should -BeFalse
        Should -Invoke Get-ScoopNativeServiceProcessId -Times 1 -Exactly
        Should -Invoke warn -Times 0 -Exactly
    }

    It 'still blocks automatic close when the native fallback identifies a service PID' {
        Mock Get-CimInstance { throw 'Access denied' }
        Mock Get-ScoopNativeServiceProcessId { @(22088) }

        Test-ScoopProcessesIncludeService -Processes @([PSCustomObject]@{ Id = 22088 }) | Should -BeTrue
        Should -Invoke warn -Times 0 -Exactly
    }

    It 'fails closed only when both service queries fail' {
        Mock Get-CimInstance { throw 'Access denied' }
        Mock Get-ScoopNativeServiceProcessId { throw 'SCM unavailable' }

        Test-ScoopProcessesIncludeService -Processes @([PSCustomObject]@{ Id = 22088 }) | Should -BeTrue
        Should -Invoke warn -Times 1 -Exactly
    }
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
