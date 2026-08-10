[CmdletBinding()]
param(
    [string]$Y8Host = '10.42.0.1',
    [ValidateRange(1, 65535)]
    [int]$Y8Port = 8555,
    [switch]$RefreshDependencies,
    [switch]$SetupOnly
)

$launcher = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) `
    'run-viewer.ps1'
& $launcher -Mode y8 -Y8Host $Y8Host -Y8Port $Y8Port `
    -RefreshDependencies:$RefreshDependencies -SetupOnly:$SetupOnly
exit $LASTEXITCODE
