# Test-only helpers for exercising install.ps1 as a black box: build a fake Cloudsmith CLI
# release (New-CloudsmithFixture), corrupt one manifest field (Set-FixtureManifestValue), and
# serve it over loopback HTTP (Start-FixtureServer). BCL + PowerShell only, so it runs unmodified
# on Windows PowerShell 5.1 and PowerShell 7.

Set-StrictMode -Version Latest

function Get-CSharpCompiler {
    [CmdletBinding()]
    param()

    $candidates = @()
    if ($env:WINDIR) {
        $frameworkRoots = @(
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework64'),
            (Join-Path $env:WINDIR 'Microsoft.NET\Framework')
        )
        foreach ($root in $frameworkRoots) {
            if (Test-Path -LiteralPath $root) {
                $candidates += Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                    Sort-Object -Property Name -Descending |
                    ForEach-Object { Join-Path $_.FullName 'csc.exe' }
            }
        }
    }

    $pathCompiler = Get-Command 'csc.exe' -ErrorAction SilentlyContinue
    if ($pathCompiler) {
        $candidates += $pathCompiler.Source
    }

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return $candidate
        }
    }

    throw "Fixture.psm1: unable to find csc.exe; install a .NET Framework C# compiler to run these tests"
}

# Compiles a real cloudsmith.exe (not a script) so install.ps1's `& $Path --version` /
# $LASTEXITCODE check exercises the same code path as a genuine released binary.
function New-FakeCloudsmithExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$Version,
        [switch]$Fail
    )

    $exitCode = if ($Fail) { 1 } else { 0 }

    # Safe to interpolate: install.ps1 validates $Version against ^[A-Za-z0-9._+-]+$ before trusting it.
    $source = @"
using System;

public static class CloudsmithFakeCli
{
    public static int Main(string[] args)
    {
        Console.WriteLine("Versions:");
        Console.WriteLine("CLI Package Version: $Version");
        Console.WriteLine("API Package Version: 2.0.27");
        return $exitCode;
    }
}
"@

    $parent = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }

    $sourcePath = [System.IO.Path]::ChangeExtension($OutputPath, '.cs')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($sourcePath, $source, $utf8NoBom)

    $compiler = Get-CSharpCompiler
    & $compiler @('/nologo', '/target:exe', "/out:$OutputPath", $sourcePath)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        throw "Fixture.psm1: csc.exe failed to compile fake cloudsmith.exe"
    }
}

# Writes a single text entry into an already-open ZipArchive.
function Add-FixtureZipEntry {
    param(
        [Parameter(Mandatory = $true)][System.IO.Compression.ZipArchive]$ZipArchive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $entry = $ZipArchive.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $writer = New-Object System.IO.StreamWriter($entry.Open())
    try {
        $writer.Write($Content)
        $writer.Flush()
    }
    finally {
        $writer.Dispose()
    }
}

# Builds a fake Cloudsmith CLI release under -Directory: a compiled cloudsmith.exe, a .zip
# archive rooted at cloudsmith/, and a manifest.txt pointing at -BaseUrl. Each option below
# corrupts one aspect of the fixture, for negative tests: -BadSchema (schema=2), -WrongTarget
# (mismatched target=), -BadSha (well-formed but wrong sha256), -FailingExecutable (exits 1),
# -ExecutableVersion (cloudsmith.exe reports a version different from the manifest),
# -EntryOutsideRoot (extra zip entry outside cloudsmith/), -TraversalEntry (../ zip entry).
function New-CloudsmithFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [string]$ExecutableVersion,
        [switch]$BadSchema,
        [switch]$WrongTarget,
        [switch]$BadSha,
        [switch]$FailingExecutable,
        [switch]$EntryOutsideRoot,
        [switch]$TraversalEntry
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $stageRoot = Join-Path $Directory "stage"
    $stageCloudsmith = Join-Path $stageRoot "cloudsmith"
    if (Test-Path -LiteralPath $stageRoot) {
        Remove-Item -LiteralPath $stageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $stageCloudsmith -Force | Out-Null

    $exePath = Join-Path $stageCloudsmith "cloudsmith.exe"
    if (-not $ExecutableVersion) {
        $ExecutableVersion = $Version
    }
    New-FakeCloudsmithExecutable -OutputPath $exePath -Version $ExecutableVersion -Fail:$FailingExecutable

    $archiveName = "cloudsmith-$Version-$Target.zip"
    $zipPath = Join-Path $Directory $archiveName
    if (Test-Path -LiteralPath $zipPath) {
        Remove-Item -LiteralPath $zipPath -Force
    }

    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        # Explicit directory entry, matching real archive layout.
        [void]$zip.CreateEntry("cloudsmith/")

        Get-ChildItem -LiteralPath $stageCloudsmith -Recurse -File | ForEach-Object {
            $relative = $_.FullName.Substring($stageCloudsmith.Length + 1).Replace('\', '/')
            $entryName = "cloudsmith/$relative"
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally {
                $entryStream.Dispose()
            }
        }

        if ($EntryOutsideRoot) {
            Add-FixtureZipEntry -ZipArchive $zip -EntryName "evil.txt" -Content "evil"
        }

        if ($TraversalEntry) {
            # install.ps1 must reject this entry name before ever extracting the archive.
            Add-FixtureZipEntry -ZipArchive $zip -EntryName "../evil.txt" -Content "evil"
        }
    }
    finally {
        $zip.Dispose()
    }

    $sha256 = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLowerInvariant()
    if ($BadSha) {
        $lastChar = $sha256.Substring(63, 1)
        $flipped = if ($lastChar -eq '0') { '1' } else { '0' }
        $sha256 = $sha256.Substring(0, 63) + $flipped
    }

    $schemaValue = if ($BadSchema) { "2" } else { "1" }
    $manifestTargetValue = if ($WrongTarget) { "$Target-other" } else { $Target }
    $trimmedBaseUrl = $BaseUrl.TrimEnd('/')
    $archiveUrl = "$trimmedBaseUrl/$archiveName"
    $manifestUrl = "$trimmedBaseUrl/manifest.txt"

    $manifestLines = @(
        "schema=$schemaValue",
        "version=$Version",
        "target=$manifestTargetValue",
        "archive=$archiveName",
        "url=$archiveUrl",
        "sha256=$sha256"
    )
    $manifestPath = Join-Path $Directory "manifest.txt"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($manifestPath, $manifestLines, $utf8NoBom)

    [PSCustomObject]@{
        Directory    = $Directory
        StageDir     = $stageCloudsmith
        ZipPath      = $zipPath
        ArchiveName  = $archiveName
        ManifestPath = $manifestPath
        Version      = $Version
        ExeVersion   = $ExecutableVersion
        Target       = $Target
        Sha256       = $sha256
        ArchiveUrl   = $archiveUrl
        ManifestUrl  = $manifestUrl
        BaseUrl      = $trimmedBaseUrl
    }
}

# Rewrites (or appends) a single key=value line in a manifest.txt, leaving everything else untouched.
function Set-FixtureManifestValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )

    $lines = [System.IO.File]::ReadAllLines($ManifestPath)
    $pattern = "^\s*$([regex]::Escape($Key))\s*="
    $found = $false
    $newLines = foreach ($line in $lines) {
        if ($line -match $pattern) {
            $found = $true
            "$Key=$Value"
        }
        else {
            $line
        }
    }
    if (-not $found) {
        $newLines = @($newLines) + "$Key=$Value"
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($ManifestPath, $newLines, $utf8NoBom)
}

# Starts a loopback-only HTTP file server rooted at -Directory on a free port, serving files as
# they exist at request time so tests can mutate them (e.g. corrupt the archive) afterward. Uses
# "localhost" rather than 127.0.0.1 because it's reserved for the current user on Windows, so no
# admin URL ACL reservation is needed. Returns an object with .Url, .Directory, .Port, and an
# idempotent .Stop() method.
function Start-FixtureServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Directory
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    # Find a free loopback port via the classic "bind to port 0" trick.
    $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $probe.Start()
    $port = $probe.LocalEndpoint.Port
    $probe.Stop()

    $prefix = "http://localhost:$port/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    $listener.Start()

    # A background runspace (not Start-Job) shares process memory, so it sees test file writes directly.
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $powershell = [System.Management.Automation.PowerShell]::Create()
    $powershell.Runspace = $runspace

    $serverLoop = {
        param($listener, $rootDirectory)

        $rootFull = [System.IO.Path]::GetFullPath($rootDirectory)

        while ($listener.IsListening) {
            try {
                $context = $listener.GetContext()
            }
            catch {
                break # Stop()/Close() was called while GetContext() was blocked; expected shutdown.
            }

            $response = $context.Response
            try {
                $relative = $context.Request.Url.LocalPath.TrimStart('/')
                $candidate = Join-Path $rootDirectory $relative
                $candidateFull = [System.IO.Path]::GetFullPath($candidate)

                if (-not $candidateFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                    -not (Test-Path -LiteralPath $candidateFull -PathType Leaf)) {
                    $response.StatusCode = 404
                }
                else {
                    $served = $false
                    $attempts = 0
                    # Retry briefly on sharing violations: the file may be mid-write from a test.
                    while (-not $served -and $attempts -lt 40) {
                        $attempts++
                        try {
                            $stream = [System.IO.File]::Open(
                                $candidateFull,
                                [System.IO.FileMode]::Open,
                                [System.IO.FileAccess]::Read,
                                [System.IO.FileShare]::ReadWrite)
                            try {
                                $response.ContentType = "application/octet-stream"
                                $response.ContentLength64 = $stream.Length
                                $stream.CopyTo($response.OutputStream)
                            }
                            finally {
                                $stream.Dispose()
                            }
                            $served = $true
                        }
                        catch [System.IO.IOException] {
                            Start-Sleep -Milliseconds 50
                        }
                    }
                    if (-not $served) {
                        $response.StatusCode = 503
                    }
                }
            }
            catch {
                try { $response.StatusCode = 500 } catch { }
            }
            finally {
                try { $response.OutputStream.Close() } catch { }
            }
        }
    }

    [void]$powershell.AddScript($serverLoop)
    [void]$powershell.AddArgument($listener)
    [void]$powershell.AddArgument($Directory)
    $asyncResult = $powershell.BeginInvoke()

    $server = [PSCustomObject]@{
        Url       = "http://localhost:$port"
        Directory = $Directory
        Port      = $port
    }
    Add-Member -InputObject $server -MemberType NoteProperty -Name Listener -Value $listener
    Add-Member -InputObject $server -MemberType NoteProperty -Name PowerShell -Value $powershell
    Add-Member -InputObject $server -MemberType NoteProperty -Name Runspace -Value $runspace
    Add-Member -InputObject $server -MemberType NoteProperty -Name AsyncResult -Value $asyncResult
    Add-Member -InputObject $server -MemberType NoteProperty -Name Stopped -Value $false
    Add-Member -InputObject $server -MemberType ScriptMethod -Name Stop -Value {
        if ($this.Stopped) { return }
        $this.Stopped = $true
        try { $this.Listener.Stop() } catch { }
        try { $this.Listener.Close() } catch { }
        try { $this.PowerShell.Stop() } catch { }
        try { [void]$this.PowerShell.EndInvoke($this.AsyncResult) } catch { }
        try { $this.PowerShell.Dispose() } catch { }
        try { $this.Runspace.Close() } catch { }
        try { $this.Runspace.Dispose() } catch { }
    }

    return $server
}

Export-ModuleMember -Function @(
    'New-FakeCloudsmithExecutable',
    'New-CloudsmithFixture',
    'Set-FixtureManifestValue',
    'Start-FixtureServer'
)
