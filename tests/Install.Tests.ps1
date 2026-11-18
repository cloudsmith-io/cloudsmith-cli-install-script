#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }

# Black-box tests: install.ps1 always runs as a child process (see Invoke-Installer), so a
# failure surfaces as a process exit code and env var overrides never leak between tests.
# These tests need a real Windows PE and self-skip on non-Windows hosts.

# $IsWindows doesn't exist in Windows PowerShell 5.1, which is always Windows.
$script:RunningOnWindows = if ($PSVersionTable.PSVersion.Major -ge 6) { $IsWindows } else { $true }

Describe 'Cloudsmith CLI installer request metadata' {

    BeforeAll {
        $installScriptPath = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') 'install.ps1')).ProviderPath
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $installScriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            throw 'install.ps1 has parse errors'
        }

        $requestFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-InstallerWebRequest'
        }, $true)
        if (-not $requestFunction) {
            throw 'unable to find Get-InstallerWebRequest'
        }

        $script:InstallerUserAgent = 'cloudsmith-cli-install-script'
        . ([scriptblock]::Create($requestFunction.Extent.Text))
    }

    It 'sets the stable user agent on secure web requests' {
        $request = Get-InstallerWebRequest -Uri 'https://downloads.example.test/archive.zip'
        try {
            $request.UserAgent | Should -Be 'cloudsmith-cli-install-script'
        }
        finally {
            $request.Abort()
        }
    }
}

Describe 'Cloudsmith CLI installer manifest URL' {

    BeforeAll {
        $installScriptPath = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') 'install.ps1')).ProviderPath
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $installScriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            throw 'install.ps1 has parse errors'
        }

        $urlFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-DefaultManifestUrl'
        }, $true)
        if (-not $urlFunction) {
            throw 'unable to find Get-DefaultManifestUrl'
        }

        $script:DownloadBaseUrl = 'https://dl.cloudsmith.io/public'
        $script:ManifestNamePrefix = 'cloudsmith-cli-manifest'
        $script:Repository = 'cloudsmith/cli'
        . ([scriptblock]::Create($urlFunction.Extent.Text))
    }

    It 'uses the manifest of the major version channel for a major version' {
        Get-DefaultManifestUrl -RequestedVersion '1' -Target 'windows-x86_64' |
            Should -Be 'https://dl.cloudsmith.io/public/cloudsmith/cli/raw/names/cloudsmith-cli-v1-manifest-windows-x86_64/versions/latest/manifest.txt'
    }

    It 'uses the version path of the latest channel for an exact version' {
        Get-DefaultManifestUrl -RequestedVersion '1.2.3' -Target 'windows-x86_64' |
            Should -Be 'https://dl.cloudsmith.io/public/cloudsmith/cli/raw/names/cloudsmith-cli-manifest-windows-x86_64/versions/1.2.3/manifest.txt'
    }
}

Describe 'Cloudsmith CLI installer activation retry' {

    BeforeAll {
        $installScriptPath = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') 'install.ps1')).ProviderPath
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $installScriptPath,
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -gt 0) {
            throw 'install.ps1 has parse errors'
        }

        $retryFunction = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Invoke-WithFilesystemRetry'
        }, $true)
        if (-not $retryFunction) {
            throw 'unable to find Invoke-WithFilesystemRetry'
        }

        . ([scriptblock]::Create($retryFunction.Extent.Text))

        $script:RetryDefaults = @{}
        foreach ($parameter in $retryFunction.Body.ParamBlock.Parameters) {
            if ($parameter.DefaultValue) {
                $script:RetryDefaults[$parameter.Name.VariablePath.UserPath] = $parameter.DefaultValue.Extent.Text
            }
        }
    }

    BeforeEach {
        $script:AttemptCount = 0
    }

    It 'succeeds after transient UnauthorizedAccessException errors, retrying only as needed' {
        $action = {
            $script:AttemptCount++
            if ($script:AttemptCount -lt 3) {
                throw [System.UnauthorizedAccessException]::new("Access to the path 'C:\fake' is denied.")
            }
            return 'moved'
        }

        $result = Invoke-WithFilesystemRetry -Action $action -Attempts 5 -DelayMilliseconds 1

        $result | Should -Be 'moved'
        $script:AttemptCount | Should -Be 3
    }

    It 'succeeds after transient IOException errors' {
        $action = {
            $script:AttemptCount++
            if ($script:AttemptCount -lt 2) {
                throw [System.IO.IOException]::new('The process cannot access the file because it is being used by another process.')
            }
            return 'moved'
        }

        $result = Invoke-WithFilesystemRetry -Action $action -Attempts 5 -DelayMilliseconds 1

        $result | Should -Be 'moved'
        $script:AttemptCount | Should -Be 2
    }

    It 'rethrows once retries are exhausted' {
        $action = {
            $script:AttemptCount++
            throw [System.UnauthorizedAccessException]::new("Access to the path 'C:\fake' is denied.")
        }

        { Invoke-WithFilesystemRetry -Action $action -Attempts 3 -DelayMilliseconds 1 } |
            Should -Throw -ExceptionType ([System.UnauthorizedAccessException])
        $script:AttemptCount | Should -Be 3
    }

    It 'does not retry unrelated exception types' {
        $action = {
            $script:AttemptCount++
            throw [System.InvalidOperationException]::new('not a filesystem access error')
        }

        { Invoke-WithFilesystemRetry -Action $action -Attempts 5 -DelayMilliseconds 1 } |
            Should -Throw -ExceptionType ([System.InvalidOperationException])
        $script:AttemptCount | Should -Be 1
    }

    It 'keeps retrying by default for long enough to outlast an antivirus scan' {
        $attempts = [int]$script:RetryDefaults['Attempts']
        $delay = [int]$script:RetryDefaults['DelayMilliseconds']

        (($attempts - 1) * $delay) | Should -BeGreaterOrEqual 9000
    }

    It 'rejects an attempt count that would skip the action' {
        { Invoke-WithFilesystemRetry -Action { 'never runs' } -Attempts 0 -DelayMilliseconds 1 } |
            Should -Throw
        { Invoke-WithFilesystemRetry -Action { 'never runs' } -DelayMilliseconds -1 } |
            Should -Throw
    }
}

Describe 'Cloudsmith CLI installer (install.ps1)' -Tag 'Windows' -Skip:(-not $script:RunningOnWindows) {

    BeforeAll {
        # Nested Join-Path: the multi-segment form is not available in Windows PowerShell 5.1.
        $script:InstallScriptPath = (Resolve-Path (Join-Path (Join-Path $PSScriptRoot '..') 'install.ps1')).ProviderPath
        Import-Module (Join-Path (Join-Path $PSScriptRoot 'helpers') 'Fixture.psm1') -Force

        $script:DefaultTarget = 'windows-x86_64'

        # Runs install.ps1 as a child process of $HostExe. -EnvironmentOverrides sets env vars for
        # the duration of the call ($null removes one) and restores the previous values afterward.
        function Invoke-Installer {
            param(
                [Parameter(Mandatory = $true)][string]$HostExe,
                [Parameter(Mandatory = $true)][string[]]$ScriptArguments,
                [hashtable]$EnvironmentOverrides = @{}
            )

            $stdErrPath = Join-Path ([System.IO.Path]::GetTempPath()) "cloudsmith-install-stderr-$([Guid]::NewGuid().ToString('N')).log"

            $previousValues = @{}
            foreach ($key in $EnvironmentOverrides.Keys) {
                $previousValues[$key] = [System.Environment]::GetEnvironmentVariable($key)
                [System.Environment]::SetEnvironmentVariable($key, $EnvironmentOverrides[$key])
            }

            try {
                # Windows PowerShell turns redirected native stderr into error records,
                # which terminate under Pester's ErrorAction Stop; scoped to this function.
                $ErrorActionPreference = 'Continue'
                $stdOutLines = @(& $HostExe -NoProfile -NoLogo -ExecutionPolicy Bypass -File $script:InstallScriptPath @ScriptArguments 2> $stdErrPath)
                $exitCode = $LASTEXITCODE
            }
            finally {
                foreach ($key in $EnvironmentOverrides.Keys) {
                    [System.Environment]::SetEnvironmentVariable($key, $previousValues[$key])
                }
            }

            $stdErrText = ''
            if (Test-Path -LiteralPath $stdErrPath) {
                $stdErrText = (Get-Content -Raw -LiteralPath $stdErrPath -ErrorAction SilentlyContinue)
                if (-not $stdErrText) { $stdErrText = '' }
                Remove-Item -LiteralPath $stdErrPath -Force -ErrorAction SilentlyContinue
            }

            [PSCustomObject]@{
                StdOut   = $stdOutLines
                StdErr   = $stdErrText
                ExitCode = $exitCode
            }
        }

        function Get-BinDirectory {
            param([string]$InstallRoot, [string]$Version, [string]$Target)
            Join-Path (Join-Path (Join-Path $InstallRoot $Version) $Target) 'cloudsmith'
        }

        function Format-ProcessArgument {
            # Minimal quoting for Start-Process -ArgumentList (used only by
            # the concurrency test, which builds a single argument string).
            param([string]$Value)
            if ($Value -match '\s') {
                return '"' + ($Value -replace '"', '\"') + '"'
            }
            return $Value
        }

        function Get-InstallerFunctionText {
            param([Parameter(Mandatory = $true)][string[]]$Names)

            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $script:InstallScriptPath,
                [ref]$tokens,
                [ref]$errors
            )
            if ($errors.Count -gt 0) {
                throw "install.ps1 has parse errors"
            }

            $functions = @($ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                    $Names -contains $node.Name
            }, $true) | Sort-Object { $_.Extent.StartOffset })

            if ($functions.Count -ne $Names.Count) {
                throw "unable to find all requested installer functions: $($Names -join ', ')"
            }

            return (($functions | ForEach-Object { $_.Extent.Text }) -join [System.Environment]::NewLine)
        }

        $script:RedirectFunctionText = Get-InstallerFunctionText -Names @(
            'Test-DownloadUriAllowed',
            'Resolve-DownloadRedirect'
        )
    }

    # Runs at discovery (BeforeAll has not executed yet); -ForEach carries the
    # host into the run phase as $currentHostExe.
    $candidateHosts = @()
    if (Get-Command 'pwsh' -ErrorAction SilentlyContinue) { $candidateHosts += 'pwsh' }
    if (Get-Command 'powershell.exe' -ErrorAction SilentlyContinue) { $candidateHosts += 'powershell.exe' }

    foreach ($currentHostExe in $candidateHosts) {

        Context "Host: $currentHostExe" -ForEach @(@{ currentHostExe = $currentHostExe }) {

            BeforeEach {
                $script:FixtureDir = Join-Path $TestDrive ("fixture-" + [Guid]::NewGuid().ToString('N'))
                New-Item -ItemType Directory -Path $script:FixtureDir -Force | Out-Null
                $script:Server = Start-FixtureServer -Directory $script:FixtureDir
                $env:CLOUDSMITH_CLI_ALLOW_INSECURE_URLS = 'true'
            }

            AfterEach {
                if ($script:Server) {
                    $script:Server.Stop()
                    $script:Server = $null
                }
                Remove-Item Env:\CLOUDSMITH_CLI_ALLOW_INSECURE_URLS -ErrorAction SilentlyContinue
            }

            It 'installs the exact requested version on the happy path' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.2.3' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.2.3',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Be 0
                $result.StdOut.Count | Should -Be 4

                $expectedBinDir = Get-BinDirectory -InstallRoot $installRoot -Version '1.2.3' -Target $script:DefaultTarget
                $expectedExecutable = Join-Path $expectedBinDir 'cloudsmith.exe'

                $result.StdOut[0] | Should -Be 'version=1.2.3'
                $result.StdOut[1] | Should -Be "target=$($script:DefaultTarget)"
                $result.StdOut[2] | Should -Be "bin_dir=$expectedBinDir"
                $result.StdOut[3] | Should -Be "executable=$expectedExecutable"

                Test-Path -LiteralPath $expectedExecutable | Should -BeTrue
                Test-Path -LiteralPath (Join-Path $expectedBinDir '.cloudsmith-installation') | Should -BeTrue

                & $expectedExecutable --version
                $LASTEXITCODE | Should -Be 0
            }

            It 'identifies PowerShell installer requests with a custom user agent' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.2.3' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.2.3',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Be 0
                $userAgentRequests = @(Get-Content -LiteralPath $script:Server.LogPath | Where-Object {
                    $_ -like 'User-Agent: cloudsmith-cli-install-script (*'
                })
                $userAgentRequests.Count | Should -Be 2
            }

            It "resolves 'latest' to the version reported in the manifest" {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '2.4.6' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', 'latest',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Be 0
                $result.StdOut[0] | Should -Be 'version=2.4.6'
            }

            It 'installs the release of the requested major version' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.19.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Be 0 -Because "stderr: $($result.StdErr)"
                $result.StdOut[0] | Should -Be 'version=1.19.0'
            }

            It 'fails when the manifest is outside the requested major version' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '10.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match "manifest resolved '10\.0\.0', expected a 1\.x release"
            }

            It 'writes exactly four lines to -OutputFile (UTF-8, no BOM) and leaves stdout empty' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $outputFile = Join-Path $TestDrive ("out-" + [Guid]::NewGuid().ToString('N') + '.txt')
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl,
                    '-OutputFile', $outputFile
                )

                $result.ExitCode | Should -Be 0
                $result.StdOut.Count | Should -Be 0

                Test-Path -LiteralPath $outputFile | Should -BeTrue
                $lines = Get-Content -LiteralPath $outputFile
                $lines.Count | Should -Be 4
                $lines[0] | Should -Be 'version=1.0.0'

                $bytes = [System.IO.File]::ReadAllBytes($outputFile)
                $hasBom = ($bytes.Length -ge 3) -and ($bytes[0] -eq 0xEF) -and ($bytes[1] -eq 0xBB) -and ($bytes[2] -eq 0xBF)
                $hasBom | Should -BeFalse
            }

            It 'installs correctly when -InstallRoot contains spaces' {
                $installRoot = Join-Path $TestDrive ("install root with spaces " + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '3.1.4' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '3.1.4',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Be 0
                $expectedExecutable = Join-Path (Get-BinDirectory -InstallRoot $installRoot -Version '3.1.4' -Target $script:DefaultTarget) 'cloudsmith.exe'
                Test-Path -LiteralPath $expectedExecutable | Should -BeTrue
            }

            It 'installs and force-reinstalls when -InstallRoot contains PowerShell wildcard characters' {
                $installRoot = Join-Path $TestDrive ("[build] root " + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '3.2.1' -Target $script:DefaultTarget -BaseUrl $script:Server.Url
                $scriptArgs = @(
                    '-Version', '3.2.1',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $first = Invoke-Installer -HostExe $currentHostExe -ScriptArguments $scriptArgs
                $first.ExitCode | Should -Be 0 -Because "stderr: $($first.StdErr)"

                $second = Invoke-Installer -HostExe $currentHostExe -ScriptArguments ($scriptArgs + '-Force')
                $second.ExitCode | Should -Be 0 -Because "stderr: $($second.StdErr)"

                $expectedBinDir = Get-BinDirectory -InstallRoot $installRoot -Version '3.2.1' -Target $script:DefaultTarget
                $expectedExecutable = Join-Path $expectedBinDir 'cloudsmith.exe'
                Test-Path -LiteralPath $expectedExecutable | Should -BeTrue

                $finalParent = Split-Path -Parent $expectedBinDir
                $activationScratch = @(Get-ChildItem -LiteralPath $finalParent -Directory -Force |
                    Where-Object { $_.Name -like '.cloudsmith.old.*' -or $_.Name -like '.cloudsmith.new.*' })
                $activationScratch.Count | Should -Be 0
            }

            It 'reuses an existing verified installation without re-downloading the archive' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '5.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url
                $scriptArgs = @(
                    '-Version', '5.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $first = Invoke-Installer -HostExe $currentHostExe -ScriptArguments $scriptArgs
                $first.ExitCode | Should -Be 0

                # Corrupt the archive without touching the manifest's sha256, so a re-download would fail checksum.
                [System.IO.File]::WriteAllBytes($fixture.ZipPath, [byte[]](1, 2, 3, 4))

                $second = Invoke-Installer -HostExe $currentHostExe -ScriptArguments $scriptArgs
                $second.ExitCode | Should -Be 0
                $second.StdErr | Should -Match 'reusing'
                ($second.StdOut -join "`n") | Should -Be ($first.StdOut -join "`n")
            }

            It '-Force reinstalls even when a valid cached installation exists' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '6.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url
                $scriptArgs = @(
                    '-Version', '6.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $first = Invoke-Installer -HostExe $currentHostExe -ScriptArguments $scriptArgs
                $first.ExitCode | Should -Be 0

                # Corrupt the archive, then force a reinstall: the checksum failure proves a re-download happened.
                [System.IO.File]::WriteAllBytes($fixture.ZipPath, [byte[]](9, 9, 9, 9))

                $forced = Invoke-Installer -HostExe $currentHostExe -ScriptArguments ($scriptArgs + '-Force')
                $forced.ExitCode | Should -Not -Be 0
                $forced.StdErr | Should -Match 'checksum mismatch'
            }

            It 'fails with a checksum mismatch and installs nothing' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.1.1' -Target $script:DefaultTarget -BaseUrl $script:Server.Url -BadSha

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.1.1',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'checksum mismatch'
                Test-Path -LiteralPath (Get-BinDirectory -InstallRoot $installRoot -Version '1.1.1' -Target $script:DefaultTarget) | Should -BeFalse
            }

            It 'rejects an unsupported manifest schema' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url -BadSchema

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'unsupported manifest schema'
            }

            It 'fails when the manifest target does not match the resolved target' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url -WrongTarget

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'does not match'
            }

            It 'fails when the requested version does not match the manifest version' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '9.9.9',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'resolved'
            }

            It 'rejects a malformed (short) sha256 in the manifest' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url
                Set-FixtureManifestValue -ManifestPath $fixture.ManifestPath -Key 'sha256' -Value 'deadbeef'

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'invalid SHA-256'
            }

            It 'rejects a zip entry outside cloudsmith/' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url -EntryOutsideRoot

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'unexpected archive entry'
            }

            It 'rejects a zip traversal entry' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url -TraversalEntry

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'unsafe archive entry'
            }

            It 'fails validation when the staged executable exits non-zero, leaving the destination clean' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url -FailingExecutable

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'failed validation'
                Test-Path -LiteralPath (Get-BinDirectory -InstallRoot $installRoot -Version '1.0.0' -Target $script:DefaultTarget) | Should -BeFalse
            }

            It 'fails validation when the staged executable reports a different version, leaving the destination clean' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -ExecutableVersion '9.9.9' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'failed validation for resolved version 1\.0\.0'
                Test-Path -LiteralPath (Get-BinDirectory -InstallRoot $installRoot -Version '1.0.0' -Target $script:DefaultTarget) | Should -BeFalse
            }

            It 'requires HTTPS unless insecure URLs are explicitly allowed' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                ) -EnvironmentOverrides @{ CLOUDSMITH_CLI_ALLOW_INSECURE_URLS = $null }

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'must use HTTPS'
            }

            It 'rejects an HTTPS-to-HTTP manifest redirect target' {
                . ([scriptblock]::Create($script:RedirectFunctionText))

                {
                    Resolve-DownloadRedirect `
                        -CurrentUri 'https://downloads.example.test/manifest.txt' `
                        -Location 'http://downloads.example.test/manifest.txt'
                } | Should -Throw -ExpectedMessage '*must use HTTPS*'
            }

            It 'rejects an HTTPS-to-HTTP archive redirect target' {
                . ([scriptblock]::Create($script:RedirectFunctionText))

                {
                    Resolve-DownloadRedirect `
                        -CurrentUri 'https://downloads.example.test/cloudsmith.zip' `
                        -Location 'http://downloads.example.test/cloudsmith.zip'
                } | Should -Throw -ExpectedMessage '*must use HTTPS*'
            }

            It 'rejects a non-.zip archive name in the manifest' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url
                # Only the archive= field is renamed; url= still points at the real .zip, so checksum still passes.
                Set-FixtureManifestValue -ManifestPath $fixture.ManifestPath -Key 'archive' -Value 'cloudsmith-1.0.0-windows-x86_64.tar.gz'

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'unsupported archive format'
            }

            It 'rejects an invalid -Version value' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0;bad',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'invalid version'
            }

            It "rejects -Version '..' before any download" {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '..',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', "$($script:Server.Url)/manifest.txt"
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'invalid version'
            }

            It "rejects -Target '.' before any download" {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', '.',
                    '-ManifestUrl', "$($script:Server.Url)/manifest.txt"
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'invalid target'
            }

            It "rejects -Target '..' before any download" {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', '1.0.0',
                    '-InstallRoot', $installRoot,
                    '-Target', '..',
                    '-ManifestUrl', "$($script:Server.Url)/manifest.txt"
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'invalid target'
            }

            It "rejects manifest version '..' before composing install paths" {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '1.0.0' -Target $script:DefaultTarget -BaseUrl $script:Server.Url
                Set-FixtureManifestValue -ManifestPath $fixture.ManifestPath -Key 'version' -Value '..'

                $result = Invoke-Installer -HostExe $currentHostExe -ScriptArguments @(
                    '-Version', 'latest',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )

                $result.ExitCode | Should -Not -Be 0
                $result.StdErr | Should -Match 'manifest contains an invalid version'
                Test-Path -LiteralPath (Join-Path $TestDrive $script:DefaultTarget) | Should -BeFalse
            }

            It 'supports two concurrent installs racing on the same InstallRoot' {
                $installRoot = Join-Path $TestDrive ("root-" + [Guid]::NewGuid().ToString('N'))
                $fixture = New-CloudsmithFixture -Directory $script:FixtureDir -Version '7.7.7' -Target $script:DefaultTarget -BaseUrl $script:Server.Url

                $argumentTokens = @(
                    '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass',
                    '-File', $script:InstallScriptPath,
                    '-Version', '7.7.7',
                    '-InstallRoot', $installRoot,
                    '-Target', $script:DefaultTarget,
                    '-ManifestUrl', $fixture.ManifestUrl
                )
                $argumentString = (($argumentTokens | ForEach-Object { Format-ProcessArgument $_ }) -join ' ')

                $out1 = Join-Path $TestDrive 'concurrent-out1.txt'
                $err1 = Join-Path $TestDrive 'concurrent-err1.txt'
                $out2 = Join-Path $TestDrive 'concurrent-out2.txt'
                $err2 = Join-Path $TestDrive 'concurrent-err2.txt'

                $proc1 = Start-Process -FilePath $currentHostExe -ArgumentList $argumentString -NoNewWindow -PassThru `
                    -RedirectStandardOutput $out1 -RedirectStandardError $err1
                $proc2 = Start-Process -FilePath $currentHostExe -ArgumentList $argumentString -NoNewWindow -PassThru `
                    -RedirectStandardOutput $out2 -RedirectStandardError $err2
                # Cache handles now, or ExitCode is null in Windows PowerShell once the process exits.
                $null = $proc1.Handle
                $null = $proc2.Handle

                $proc1.WaitForExit(60000) | Out-Null
                $proc2.WaitForExit(60000) | Out-Null

                $stderr1 = if (Test-Path -LiteralPath $err1) { Get-Content -Raw -LiteralPath $err1 } else { '' }
                $stderr2 = if (Test-Path -LiteralPath $err2) { Get-Content -Raw -LiteralPath $err2 } else { '' }
                $proc1.ExitCode | Should -Be 0 -Because "stderr: $stderr1"
                $proc2.ExitCode | Should -Be 0 -Because "stderr: $stderr2"

                $expectedExecutable = Join-Path (Get-BinDirectory -InstallRoot $installRoot -Version '7.7.7' -Target $script:DefaultTarget) 'cloudsmith.exe'
                Test-Path -LiteralPath $expectedExecutable | Should -BeTrue

                & $expectedExecutable --version
                $LASTEXITCODE | Should -Be 0
            }
        }
    }
}
