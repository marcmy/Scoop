# Relaunch integration for automatic process restart during updates.
#
# Some applications are built as console-subsystem executables even though they
# behave like desktop or tray apps. Launching those through Start-Process or
# ShellExecute can attach them to Scoop's current console, keeping the terminal
# window alive and causing the app to exit when that window is closed.
#
# CreateProcess with DETACHED_PROCESS prevents the restarted app from inheriting
# the updater's console. Handle inheritance is also disabled explicitly.

function Initialize-ScoopDetachedProcessLauncher {
    if ('Scoop.NativeProcessLauncher' -as [Type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace Scoop
{
    public static class NativeProcessLauncher
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX;
            public int dwY;
            public int dwXSize;
            public int dwYSize;
            public int dwXCountChars;
            public int dwYCountChars;
            public int dwFillAttribute;
            public int dwFlags;
            public short wShowWindow;
            public short cbReserved2;
            public IntPtr lpReserved2;
            public IntPtr hStdInput;
            public IntPtr hStdOutput;
            public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess;
            public IntPtr hThread;
            public uint dwProcessId;
            public uint dwThreadId;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(
            string lpApplicationName,
            StringBuilder lpCommandLine,
            IntPtr lpProcessAttributes,
            IntPtr lpThreadAttributes,
            bool bInheritHandles,
            uint dwCreationFlags,
            IntPtr lpEnvironment,
            string lpCurrentDirectory,
            ref STARTUPINFO lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static void StartDetached(string filePath, string workingDirectory)
        {
            const uint DETACHED_PROCESS = 0x00000008;
            const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
            const uint CREATE_DEFAULT_ERROR_MODE = 0x04000000;

            var startupInfo = new STARTUPINFO();
            startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));

            var commandLine = new StringBuilder("\"" + filePath + "\"");
            PROCESS_INFORMATION processInfo;

            bool created = CreateProcessW(
                filePath,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_DEFAULT_ERROR_MODE,
                IntPtr.Zero,
                workingDirectory,
                ref startupInfo,
                out processInfo);

            if (!created)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            if (processInfo.hThread != IntPtr.Zero)
            {
                CloseHandle(processInfo.hThread);
            }
            if (processInfo.hProcess != IntPtr.Zero)
            {
                CloseHandle(processInfo.hProcess);
            }
        }
    }
}
'@
}

function Start-ScoopDetachedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [String] $FilePath,
        [Parameter(Mandatory = $true)]
        [String] $WorkingDirectory
    )

    Initialize-ScoopDetachedProcessLauncher
    [Scoop.NativeProcessLauncher]::StartDetached($FilePath, $WorkingDirectory)
}

function Start-ScoopAppAfterUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject] $State,
        [Switch] $PreferOriginalPath
    )

    foreach ($restartExecutable in @($State.RestartExecutables)) {
        if (Test-ScoopAppExecutableRunning -State $State -RelativePath $restartExecutable.RelativePath) {
            continue
        }

        $targetPath = Resolve-ScoopRestartExecutable -State $State -RestartExecutable $restartExecutable -PreferOriginalPath:$PreferOriginalPath
        if (!$targetPath) {
            warn "Could not restart '$($State.App)': executable not found."
            continue
        }

        Write-Host "Restarting '$($State.App)': $(friendly_path $targetPath)"
        try {
            Start-ScoopDetachedProcess -FilePath $targetPath -WorkingDirectory (Split-Path -Parent $targetPath)
        } catch {
            warn "Could not restart '$($State.App)': $($_.Exception.Message)"
        }
    }
}
