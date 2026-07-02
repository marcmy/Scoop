# Relaunch integration for automatic process restart during updates.
#
# Some desktop and tray applications retain the updater's console streams even
# when they do not share its process lifetime. That can keep a script terminal
# open, interleave application logs with Scoop output, or make the application
# react badly when the terminal is closed.
#
# CreateProcess with DETACHED_PROCESS prevents console-subsystem applications
# from inheriting the updater's console. STARTF_USESTDHANDLES additionally binds
# stdin, stdout, and stderr to NUL so GUI-subsystem applications such as Electron
# do not retain the terminal's ConPTY or console-buffer handles.

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

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)]
            public bool bInheritHandle;
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

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(
            string lpFileName,
            uint dwDesiredAccess,
            uint dwShareMode,
            ref SECURITY_ATTRIBUTES lpSecurityAttributes,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        public static void StartDetached(string filePath, string workingDirectory)
        {
            const uint DETACHED_PROCESS = 0x00000008;
            const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
            const uint CREATE_DEFAULT_ERROR_MODE = 0x04000000;
            const int STARTF_USESTDHANDLES = 0x00000100;

            const uint GENERIC_READ = 0x80000000;
            const uint GENERIC_WRITE = 0x40000000;
            const uint FILE_SHARE_READ = 0x00000001;
            const uint FILE_SHARE_WRITE = 0x00000002;
            const uint OPEN_EXISTING = 3;
            const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

            var securityAttributes = new SECURITY_ATTRIBUTES();
            securityAttributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            securityAttributes.lpSecurityDescriptor = IntPtr.Zero;
            securityAttributes.bInheritHandle = true;

            IntPtr nullHandle = CreateFileW(
                "NUL",
                GENERIC_READ | GENERIC_WRITE,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                ref securityAttributes,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                IntPtr.Zero);

            if (nullHandle == new IntPtr(-1))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            var processInfo = new PROCESS_INFORMATION();
            try
            {
                var startupInfo = new STARTUPINFO();
                startupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                startupInfo.dwFlags = STARTF_USESTDHANDLES;
                startupInfo.hStdInput = nullHandle;
                startupInfo.hStdOutput = nullHandle;
                startupInfo.hStdError = nullHandle;

                var commandLine = new StringBuilder("\"" + filePath + "\"");
                bool created = CreateProcessW(
                    filePath,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_DEFAULT_ERROR_MODE,
                    IntPtr.Zero,
                    workingDirectory,
                    ref startupInfo,
                    out processInfo);

                if (!created)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                if (processInfo.hThread != IntPtr.Zero)
                {
                    CloseHandle(processInfo.hThread);
                }
                if (processInfo.hProcess != IntPtr.Zero)
                {
                    CloseHandle(processInfo.hProcess);
                }
                CloseHandle(nullHandle);
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
