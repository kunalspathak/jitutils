# Initialize variables if they aren't already defined.
# These may be defined as parameters of the importing script, or set after importing this script.

# CI mode - set to true on CI server for PR validation build or official build.
[bool]$ci = if (Test-Path variable:ci) { $ci } else { $false }

# Build configuration. Common values include 'Debug' and 'Release', but the repository may use other names.
[string]$configuration = if (Test-Path variable:configuration) { $configuration } else { 'Debug' }

# Set to true to opt out of outputting binary log while running in CI
[bool]$excludeCIBinarylog = if (Test-Path variable:excludeCIBinarylog) { $excludeCIBinarylog } else { $false }

# Set to true to output binary log from msbuild. Note that emitting binary log slows down the build.
[bool]$binaryLog = if (Test-Path variable:binaryLog) { $binaryLog } else { $ci -and !$excludeCIBinarylog }

# Set to true to use the pipelines logger which will enable Azure logging output.
# https://github.com/Microsoft/azure-pipelines-tasks/blob/master/docs/authoring/commands.md
# This flag is meant as a temporary opt-opt for the feature while validate it across
# our consumers. It will be deleted in the future.
[bool]$pipelinesLog = if (Test-Path variable:pipelinesLog) { $pipelinesLog } else { $ci }

# Turns on machine preparation/clean up code that changes the machine state (e.g. kills build processes).
[bool]$prepareMachine = if (Test-Path variable:prepareMachine) { $prepareMachine } else { $false }

# True to restore toolsets and dependencies.
[bool]$restore = if (Test-Path variable:restore) { $restore } else { $true }

# Adjusts msbuild verbosity level.
[string]$verbosity = if (Test-Path variable:verbosity) { $verbosity } else { 'minimal' }

# Set to true to reuse msbuild nodes. Recommended to not reuse on CI.
[bool]$nodeReuse = if (Test-Path variable:nodeReuse) { $nodeReuse } else { !$ci }

# Configures warning treatment in msbuild.
[bool]$warnAsError = if (Test-Path variable:warnAsError) { $warnAsError } else { $true }

# Specifies which msbuild engine to use for build: 'vs', 'dotnet' or unspecified (determined based on presence of tools.vs in global.json).
[string]$msbuildEngine = if (Test-Path variable:msbuildEngine) { $msbuildEngine } else { $null }

# True to attempt using .NET Core already that meets requirements specified in global.json
# installed on the machine instead of downloading one.
[bool]$useInstalledDotNetCli = if (Test-Path variable:useInstalledDotNetCli) { $useInstalledDotNetCli } else { $true }

# Enable repos to use a particular version of the on-line dotnet-install scripts.
#    default URL: https://dot.net/v1/dotnet-install.ps1
[string]$dotnetInstallScriptVersion = if (Test-Path variable:dotnetInstallScriptVersion) { $dotnetInstallScriptVersion } else { 'v1' }

# True to use global NuGet cache instead of restoring packages to repository-local directory.
[bool]$useGlobalNuGetCache = if (Test-Path variable:useGlobalNuGetCache) { $useGlobalNuGetCache } else { !$ci }

# An array of names of processes to stop on script exit if prepareMachine is true.
$processesToStopOnExit = if (Test-Path variable:processesToStopOnExit) { $processesToStopOnExit } else { @('msbuild', 'dotnet', 'vbcscompiler') }

$disableConfigureToolsetImport = if (Test-Path variable:disableConfigureToolsetImport) { $disableConfigureToolsetImport } else { $null }

set-strictmode -version 2.0
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# If specified, provides an alternate path for getting .NET Core SDKs and Runtimes. This script will still try public sources first.
[string]$runtimeSourceFeed = if (Test-Path variable:runtimeSourceFeed) { $runtimeSourceFeed } else { $null }
# Base-64 encoded SAS token that has permission to storage container described by $runtimeSourceFeed
[string]$runtimeSourceFeedKey = if (Test-Path variable:runtimeSourceFeedKey) { $runtimeSourceFeedKey } else { $null }

# If false, use copy of dotnet-install from /eng/common/dotnet-install-scripts (for custom behaviors).
# otherwise will fetch from public location.
[bool]$useDefaultDotnetInstall = if (Test-Path variable:useDefaultDotnetInstall) { $useDefaultDotnetInstall } else { $true }

function Create-Directory ([string[]] $path) {
    New-Item -Path $path -Force -ItemType 'Directory' | Out-Null
}

function Unzip([string]$zipfile, [string]$outpath) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile, $outpath)
}

# This will exec a process using the console and return it's exit code.
# This will not throw when the process fails.
# Returns process exit code.
function Exec-Process([string]$command, [string]$commandArgs) {
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $command
  $startInfo.Arguments = $commandArgs
  $startInfo.UseShellExecute = $false
  $startInfo.WorkingDirectory = Get-Location

  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $startInfo
  $process.Start() | Out-Null

  $finished = $false
  try {
    while (-not $process.WaitForExit(100)) {
      # Non-blocking loop done to allow ctr-c interrupts
    }

    $finished = $true
    return $global:LASTEXITCODE = $process.ExitCode
  }
  finally {
    # If we didn't finish then an error occurred or the user hit ctrl-c.  Either
    # way kill the process
    if (-not $finished) {
      $process.Kill()
    }
  }
}

# createSdkLocationFile parameter enables a file being generated under the toolset directory
# which writes the sdk's location into. This is only necessary for cmd --> powershell invocations
# as dot sourcing isn't possible.
function InitializeDotNetCli([bool]$install, [bool]$createSdkLocationFile) {
  if (Test-Path variable:global:_DotNetInstallDir) {
    return $global:_DotNetInstallDir
  }

  # Don't resolve runtime, shared framework, or SDK from other locations to ensure build determinism
  $env:DOTNET_MULTILEVEL_LOOKUP=0

  # Disable first run since we do not need all ASP.NET packages restored.
  $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1

  # Disable telemetry on CI.
  if ($ci) {
    $env:DOTNET_CLI_TELEMETRY_OPTOUT=1
  }

  # Source Build uses DotNetCoreSdkDir variable
  if ($env:DotNetCoreSdkDir -ne $null) {
    $env:DOTNET_INSTALL_DIR = $env:DotNetCoreSdkDir
  }

  # Find the first path on %PATH% that contains the dotnet.exe
  if ($useInstalledDotNetCli -and (-not $globalJsonHasRuntimes) -and ($env:DOTNET_INSTALL_DIR -eq $null)) {
    $dotnetExecutable = GetExecutableFileName 'dotnet'
    $dotnetCmd = Get-Command $dotnetExecutable -ErrorAction SilentlyContinue

    if ($dotnetCmd -ne $null) {
      $env:DOTNET_INSTALL_DIR = Split-Path $dotnetCmd.Path -Parent
    }
  }

  $dotnetSdkVersion = $GlobalJson.tools.dotnet

  # Use dotnet installation specified in DOTNET_INSTALL_DIR if it contains the required SDK version,
  # otherwise install the dotnet CLI and SDK to repo local .dotnet directory to avoid potential permission issues.
  if ((-not $globalJsonHasRuntimes) -and ($env:DOTNET_INSTALL_DIR -ne $null) -and (Test-Path(Join-Path $env:DOTNET_INSTALL_DIR "sdk\$dotnetSdkVersion"))) {
    $dotnetRoot = $env:DOTNET_INSTALL_DIR
  } else {
    $dotnetRoot = Join-Path $RepoRoot '.dotnet'

    if (-not (Test-Path(Join-Path $dotnetRoot "sdk\$dotnetSdkVersion"))) {
      if ($install) {
        InstallDotNetSdk $dotnetRoot $dotnetSdkVersion
      } else {
        Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Unable to find dotnet with SDK version '$dotnetSdkVersion'"
        ExitWithExitCode 1
      }
    }

    $env:DOTNET_INSTALL_DIR = $dotnetRoot
  }

  # Creates a temporary file under the toolset dir.
  # The following code block is protecting against concurrent access so that this function can
  # be called in parallel.
  if ($createSdkLocationFile) {
    do {
      $sdkCacheFileTemp = Join-Path $ToolsetDir $([System.IO.Path]::GetRandomFileName())
    }
    until (!(Test-Path $sdkCacheFileTemp))
    Set-Content -Path $sdkCacheFileTemp -Value $dotnetRoot

    try {
      Rename-Item -Force -Path $sdkCacheFileTemp 'sdk.txt'
    } catch {
      # Somebody beat us
      Remove-Item -Path $sdkCacheFileTemp
    }
  }

  # Add dotnet to PATH. This prevents any bare invocation of dotnet in custom
  # build steps from using anything other than what we've downloaded.
  # It also ensures that VS msbuild will use the downloaded sdk targets.
  $env:PATH = "$dotnetRoot;$env:PATH"

  # Make Sure that our bootstrapped dotnet cli is available in future steps of the Azure Pipelines build
  Write-PipelinePrependPath -Path $dotnetRoot

  Write-PipelineSetVariable -Name 'DOTNET_MULTILEVEL_LOOKUP' -Value '0'
  Write-PipelineSetVariable -Name 'DOTNET_SKIP_FIRST_TIME_EXPERIENCE' -Value '1'

  return $global:_DotNetInstallDir = $dotnetRoot
}

function GetDotNetInstallScript([string] $dotnetRoot) {
  $installScript = Join-Path $dotnetRoot 'dotnet-install.ps1'
  if (!(Test-Path $installScript)) {
    create-directory $dotnetroot

    if ($useDefaultDotnetInstall)
    {
      $progresspreference = 'silentlycontinue' # don't display the console progress ui - it's a huge perf hit

      $maxretries = 5
      $retries = 1

      $uri = "https://dot.net/$dotnetinstallscriptversion/dotnet-install.ps1"

      while($true) {
        try {
          write-host "get $uri"
          invoke-webrequest $uri -outfile $installscript
          break
        }
        catch {
          write-host "failed to download '$uri'"
          write-error $_.exception.message -erroraction continue
        }

        if (++$retries -le $maxretries) {
          $delayinseconds = [math]::pow(2, $retries) - 1 # exponential backoff
          write-host "retrying. waiting for $delayinseconds seconds before next attempt ($retries of $maxretries)."
          start-sleep -seconds $delayinseconds
        }
        else {
          throw "unable to download file in $maxretries attempts."
        }
      }
    }
    else
    {
      # Use a special version of the script from eng/common that understands the existence of a "productVersion.txt" in a dotnet path.
      # See https://github.com/dotnet/arcade/issues/6047 for details
      $engCommonCopy = Resolve-Path (Join-Path $PSScriptRoot 'dotnet-install-scripts\dotnet-install.ps1')
      Copy-Item $engCommonCopy -Destination $installScript -Force
    }
  }
  return $installScript
}

function InstallDotNetSdk([string] $dotnetRoot, [string] $version, [string] $architecture = '') {
  InstallDotNet $dotnetRoot $version $architecture '' $false $runtimeSourceFeed $runtimeSourceFeedKey
}

function InstallDotNet([string] $dotnetRoot,
  [string] $version,
  [string] $architecture = '',
  [string] $runtime = '',
  [bool] $skipNonVersionedFiles = $false,
  [string] $runtimeSourceFeed = '',
  [string] $runtimeSourceFeedKey = '') {

  $installScript = GetDotNetInstallScript $dotnetRoot
  $installParameters = @{
    Version = $version
    InstallDir = $dotnetRoot
  }

  if ($architecture) { $installParameters.Architecture = $architecture }
  if ($runtime) { $installParameters.Runtime = $runtime }
  if ($skipNonVersionedFiles) { $installParameters.SkipNonVersionedFiles = $skipNonVersionedFiles }

  try {
    & $installScript @installParameters
  }
  catch {
    if ($runtimeSourceFeed -or $runtimeSourceFeedKey) {
      Write-Host "Failed to install dotnet from public location. Trying from '$runtimeSourceFeed'"
      if ($runtimeSourceFeed) { $installParameters.AzureFeed = $runtimeSourceFeed }

      if ($runtimeSourceFeedKey) {
        $decodedBytes = [System.Convert]::FromBase64String($runtimeSourceFeedKey)
        $decodedString = [System.Text.Encoding]::UTF8.GetString($decodedBytes)
        $installParameters.FeedCredential = $decodedString
      }

      try {
        & $installScript @installParameters
      }
      catch {
        Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Failed to install dotnet from custom location '$runtimeSourceFeed'."
        ExitWithExitCode 1
      }
    } else {
      Write-PipelineTelemetryError -Category 'InitializeToolset' -Message "Failed to install dotnet from public location."
      ExitWithExitCode 1
    }
  }
}

function ExitWithExitCode([int] $exitCode) {
  if ($ci -and $prepareMachine) {
    Stop-Processes
  }
  exit $exitCode
}

function Stop-Processes() {
  Write-Host 'Killing running build processes...'
  foreach ($processName in $processesToStopOnExit) {
    Get-Process -Name $processName -ErrorAction SilentlyContinue | Stop-Process
  }
}


function GetExecutableFileName($baseName) {
  if (IsWindowsPlatform) {
    return "$baseName.exe"
  }
  else {
    return $baseName
  }
}

function IsWindowsPlatform() {
  return [environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

. $PSScriptRoot\pipeline-logging-functions.ps1

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\')
$EngRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$ArtifactsDir = Join-Path $RepoRoot 'artifacts'
$ToolsetDir = Join-Path $ArtifactsDir 'toolset'
$ToolsDir = Join-Path $RepoRoot '.tools'
$LogDir = Join-Path (Join-Path $ArtifactsDir 'log') $configuration
$TempDir = Join-Path (Join-Path $ArtifactsDir 'tmp') $configuration
$GlobalJson = Get-Content -Raw -Path (Join-Path $RepoRoot 'global.json') | ConvertFrom-Json
# true if global.json contains a "runtimes" section
$globalJsonHasRuntimes = if ($GlobalJson.tools.PSObject.Properties.Name -Match 'runtimes') { $true } else { $false }

Create-Directory $ToolsetDir
Create-Directory $TempDir
Create-Directory $LogDir

Write-PipelineSetVariable -Name 'Artifacts' -Value $ArtifactsDir
Write-PipelineSetVariable -Name 'Artifacts.Toolset' -Value $ToolsetDir
Write-PipelineSetVariable -Name 'Artifacts.Log' -Value $LogDir
Write-PipelineSetVariable -Name 'TEMP' -Value $TempDir
Write-PipelineSetVariable -Name 'TMP' -Value $TempDir

# Import custom tools configuration, if present in the repo.
# Note: Import in global scope so that the script set top-level variables without qualification.
if (!$disableConfigureToolsetImport) {
  $configureToolsetScript = Join-Path $EngRoot 'configure-toolset.ps1'
  if (Test-Path $configureToolsetScript) {
    . $configureToolsetScript
    if ((Test-Path variable:failOnConfigureToolsetError) -And $failOnConfigureToolsetError) {
      if ((Test-Path variable:LastExitCode) -And ($LastExitCode -ne 0)) {
        Write-PipelineTelemetryError -Category 'Build' -Message 'configure-toolset.ps1 returned a non-zero exit code'
        ExitWithExitCode $LastExitCode
      }
    }
  }
}
