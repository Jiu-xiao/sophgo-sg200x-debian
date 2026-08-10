[CmdletBinding()]
param(
    [ValidateSet('rtsp', 'y8')]
    [string]$Mode = 'rtsp',
    [string]$Url = 'rtsp://10.42.0.1:8554/live',
    [string]$Y8Host = '10.42.0.1',
    [ValidateRange(1, 65535)]
    [int]$Y8Port = 8555,
    [switch]$RefreshDependencies,
    [switch]$SetupOnly
)

# Creates a user-local virtual environment and starts the interactive viewer.

$ErrorActionPreference = 'Stop'
$toolDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$requirements = Join-Path $toolDirectory 'requirements.txt'
$viewer = if ($Mode -eq 'y8') {
    Join-Path $toolDirectory 'y8_viewer.py'
} else {
    Join-Path $toolDirectory 'viewer.py'
}
$basePython = (Get-Command python -ErrorAction Stop).Source
$runtimeRoot = Join-Path $env:LOCALAPPDATA 'MaixCAM\camera-viewer'
$virtualEnvironment = Join-Path $runtimeRoot 'venv'
$venvPython = Join-Path $virtualEnvironment 'Scripts\python.exe'
$stamp = Join-Path $runtimeRoot 'requirements.sha256'
$requirementsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $requirements).
    Hash.ToLowerInvariant()

New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
if (-not (Test-Path -LiteralPath $venvPython)) {
    & $basePython -m venv $virtualEnvironment
    if ($LASTEXITCODE -ne 0) {
        throw "failed to create viewer virtual environment: $LASTEXITCODE"
    }
}

$installedHash = if (Test-Path -LiteralPath $stamp) {
    (Get-Content -Raw -LiteralPath $stamp).Trim()
} else {
    ''
}
if ($RefreshDependencies -or $installedHash -ne $requirementsHash) {
    & $venvPython -m pip install --disable-pip-version-check --requirement $requirements
    if ($LASTEXITCODE -ne 0) {
        throw "failed to install viewer dependencies: $LASTEXITCODE"
    }
    [IO.File]::WriteAllText(
        $stamp,
        "$requirementsHash`n",
        [Text.UTF8Encoding]::new($false)
    )
}

if ($SetupOnly) {
    Write-Host "VIEWER_ENVIRONMENT=$virtualEnvironment"
    Write-Host "REQUIREMENTS_SHA256=$requirementsHash"
    exit 0
}

if ($Mode -eq 'y8') {
    & $venvPython $viewer --host $Y8Host --port $Y8Port
} else {
    & $venvPython $viewer --url $Url
}
exit $LASTEXITCODE
