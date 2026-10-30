param([string]$Lua)
$ErrorActionPreference = 'Stop'
# Keep SDK first-run state and NuGet caches inside this offline tooling folder.
$names = @('DOTNET_CLI_HOME', 'NUGET_PACKAGES', 'APPDATA', 'DOTNET_CLI_TELEMETRY_OPTOUT', 'DOTNET_GENERATE_ASPNET_CERTIFICATE')
$previous = @{}
foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:DOTNET_CLI_HOME = Join-Path $PSScriptRoot '.local'
    $env:NUGET_PACKAGES = Join-Path $PSScriptRoot '.local/packages'
    $env:APPDATA = Join-Path $PSScriptRoot '.local/appdata'
    $env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
    $env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
    $project = Join-Path $PSScriptRoot 'Kairos.Translator.Tests/Kairos.Translator.Tests.csproj'
    dotnet restore $project --configfile (Join-Path $PSScriptRoot 'NuGet.Config')
    if ($LASTEXITCODE -ne 0) { throw 'Restore failed' }
    $arguments = @('run', '--no-restore', '--project', $project)
    if ($Lua) { $arguments += @('--', '--lua', $Lua) }
    dotnet @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
}
