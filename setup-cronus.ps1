# ============================================================================
# Cronus Agent Developer Setup Script (Windows / PowerShell)
# ============================================================================
# Quick setup for developers who cloned the repo manually.
# Mirrors setup-cronus.sh for Windows native environments.
#
# Usage (from repo root):
#   .\setup-cronus.ps1
#
# This script:
#   1. Locates or installs uv
#   2. Ensures Python 3.11 is available (via uv if needed)
#   3. Creates a Python 3.11 virtual environment at .\venv
#   4. Installs [all] + [windows] extras (hash-verified via uv.lock when present)
#   5. Creates .env from template (if it does not already exist)
#   6. Adds venv\Scripts to the user PATH and sets CRONUS_HOME
#   7. Seeds bundled skills into %LOCALAPPDATA%\cronus\skills
#   8. Optionally runs the setup wizard
# ============================================================================

[CmdletBinding()]
param(
    [switch]$SkipSetup,
    [switch]$NoVenv
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# Force UTF-8 console output so box-drawing chars render correctly
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new() } catch { }

$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$PythonVersion = "3.11"
$CronusHome    = if ($env:CRONUS_HOME) { $env:CRONUS_HOME } else { "$env:LOCALAPPDATA\cronus" }

# ============================================================================
# Output helpers
# ============================================================================

function Write-Info    { param([string]$m); Write-Host "-> $m" -ForegroundColor Cyan    }
function Write-Success { param([string]$m); Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn    { param([string]$m); Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param([string]$m); Write-Host "[X] $m" -ForegroundColor Red    }

# ============================================================================
# Banner
# ============================================================================

Write-Host ""
Write-Host "+---------------------------------------------------------+" -ForegroundColor Magenta
Write-Host "|           Cronus Agent Developer Setup                  |" -ForegroundColor Magenta
Write-Host "+---------------------------------------------------------+" -ForegroundColor Magenta
Write-Host ""

Set-Location $ScriptDir

# Prevent uv from picking up stray config files from another user's home
# when the script runs elevated or under a different account.
$env:UV_NO_CONFIG = "1"

# ============================================================================
# Locate or install uv
# ============================================================================

Write-Info "Checking for uv..."

$UvCmd = $null
foreach ($candidate in @(
    (Get-Command uv -ErrorAction SilentlyContinue)?.Source,
    "$env:USERPROFILE\.local\bin\uv.exe",
    "$env:USERPROFILE\.cargo\bin\uv.exe",
    "$env:LOCALAPPDATA\uv\bin\uv.exe"
)) {
    if ($candidate -and (Test-Path $candidate)) {
        $UvCmd = $candidate
        break
    }
}

if ($UvCmd) {
    $uvVer = & $UvCmd --version 2>$null
    Write-Success "uv found ($uvVer)"
} else {
    Write-Info "uv not found — installing via astral.sh installer..."
    $uvInstaller = "$env:TEMP\uv-install.ps1"
    try {
        Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" -OutFile $uvInstaller -UseBasicParsing
        & powershell -ExecutionPolicy Bypass -File $uvInstaller
    } catch {
        Write-Err "Failed to download or run uv installer: $_"
        Write-Info "Install manually: https://docs.astral.sh/uv/getting-started/installation/"
        exit 1
    } finally {
        Remove-Item $uvInstaller -ErrorAction SilentlyContinue
    }

    foreach ($candidate in @(
        "$env:USERPROFILE\.local\bin\uv.exe",
        "$env:LOCALAPPDATA\uv\bin\uv.exe",
        "$env:USERPROFILE\.cargo\bin\uv.exe"
    )) {
        if (Test-Path $candidate) { $UvCmd = $candidate; break }
    }

    if (-not $UvCmd) {
        Write-Err "uv installer ran but uv binary not found. Open a new terminal and retry."
        exit 1
    }
    $uvVer = & $UvCmd --version 2>$null
    Write-Success "uv installed ($uvVer)"
}

# ============================================================================
# Python 3.11
# ============================================================================

Write-Info "Checking Python $PythonVersion..."

$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$pythonPath = & $UvCmd python find $PythonVersion 2>$null
$ErrorActionPreference = $prevEAP

if ($pythonPath -and (Test-Path $pythonPath)) {
    $pyVer = & $pythonPath --version 2>$null
    Write-Success "$pyVer found"
} else {
    Write-Info "Python $PythonVersion not found — installing via uv..."
    & $UvCmd python install $PythonVersion
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to install Python $PythonVersion via uv."
        exit 1
    }
    $pythonPath = & $UvCmd python find $PythonVersion 2>$null
    $pyVer = & $pythonPath --version 2>$null
    Write-Success "$pyVer installed"
}

# ============================================================================
# Virtual environment
# ============================================================================

if (-not $NoVenv) {
    Write-Info "Setting up virtual environment..."

    if (Test-Path "venv") {
        Write-Info "Removing existing venv..."
        Remove-Item -Recurse -Force "venv"
    }

    & $UvCmd venv venv --python $PythonVersion
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Failed to create virtual environment."
        exit 1
    }
    Write-Success "venv created (Python $PythonVersion)"
}

$VenvPython = "$ScriptDir\venv\Scripts\python.exe"

# ============================================================================
# Dependencies
# ============================================================================

Write-Info "Installing dependencies..."

if (-not $NoVenv) {
    $env:VIRTUAL_ENV            = "$ScriptDir\venv"
    $env:UV_PROJECT_ENVIRONMENT = "$ScriptDir\venv"
}

$installed = $false

# Tier 0: hash-verified install via uv.lock (preferred — protects against
# compromised transitives; same strategy as setup-cronus.sh and install.ps1).
if (Test-Path "uv.lock") {
    Write-Info "uv.lock found — using hash-verified install (uv sync --locked)..."
    Write-Info "(First run on a fresh venv can take 1-5 minutes; uv prints progress below)"
    & $UvCmd sync --extra all --extra windows --locked
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Dependencies installed (hash-verified via uv.lock)"
        $installed = $true
    } else {
        Write-Warn "uv.lock sync failed — falling back to PyPI resolve (transitives not hash-verified)..."
    }
}

# Tier 1: [all,windows] — curated extras
if (-not $installed) {
    Write-Info "Trying: .[all,windows]..."
    & $UvCmd pip install -e ".[all,windows]"
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Dependencies installed ([all,windows])"
        $installed = $true
    } else {
        Write-Warn ".[all,windows] failed — trying .[all]..."
    }
}

# Tier 2: [all] without windows extra
if (-not $installed) {
    & $UvCmd pip install -e ".[all]"
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Dependencies installed ([all])"
        $installed = $true
    } else {
        Write-Warn ".[all] failed — trying core only..."
    }
}

# Tier 3: bare install — last resort so at least the CLI launches
if (-not $installed) {
    & $UvCmd pip install -e "."
    if ($LASTEXITCODE -eq 0) {
        Write-Success "Dependencies installed (core only — some features may be unavailable)"
        $installed = $true
    }
}

if (-not $installed) {
    Write-Err "All install tiers failed. See uv output above for details."
    exit 1
}

# Baseline import probe — confirms deps landed in the right venv
if (-not $NoVenv -and (Test-Path $VenvPython)) {
    Write-Info "Verifying baseline imports..."
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $VenvPython -c "import dotenv, openai, rich, prompt_toolkit" 2>&1 | Out-Null
    $importOk = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP
    if ($importOk -ne 0) {
        Write-Warn "Baseline imports failed in .\venv — dependencies may have landed in a sibling .venv\"
        Write-Info "Recover with: `$env:UV_PROJECT_ENVIRONMENT='$ScriptDir\venv'; uv sync --extra all --locked"
    } else {
        Write-Success "Baseline imports verified"
    }
}

# ============================================================================
# .env file
# ============================================================================

if (-not (Test-Path ".env")) {
    if (Test-Path ".env.example") {
        Copy-Item ".env.example" ".env"
        Write-Success "Created .env from template"
    }
} else {
    Write-Info ".env already exists — keeping it"
}

# ============================================================================
# PATH and CRONUS_HOME
# ============================================================================

Write-Info "Setting up cronus command..."

$cronusBin = "$ScriptDir\venv\Scripts"

$currentPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($currentPath -notlike "*$cronusBin*") {
    [Environment]::SetEnvironmentVariable("Path", "$cronusBin;$currentPath", "User")
    Write-Success "Added to user PATH: $cronusBin"
} else {
    Write-Info "PATH already includes $cronusBin"
}

# Set CRONUS_HOME so the agent stores config/data in the right place on Windows
# (%LOCALAPPDATA%\cronus instead of the Unix default ~/.cronus).
$existingHome = [Environment]::GetEnvironmentVariable("CRONUS_HOME", "User")
if (-not $existingHome -or $existingHome -ne $CronusHome) {
    [Environment]::SetEnvironmentVariable("CRONUS_HOME", $CronusHome, "User")
    Write-Success "Set CRONUS_HOME=$CronusHome"
}

# Update the current session immediately
$env:Path       = "$cronusBin;$env:Path"
$env:CRONUS_HOME = $CronusHome

Write-Success "cronus command ready"

# ============================================================================
# Configuration directories
# ============================================================================

Write-Info "Setting up Cronus home directory..."

foreach ($subdir in @("cron","sessions","logs","pairing","hooks","image_cache","audio_cache","memories","skills")) {
    New-Item -ItemType Directory -Force -Path "$CronusHome\$subdir" | Out-Null
}

# .env in CRONUS_HOME (user-level API keys / config)
$cronusEnv = "$CronusHome\.env"
if (-not (Test-Path $cronusEnv)) {
    if (Test-Path ".env.example") {
        Copy-Item ".env.example" $cronusEnv
        Write-Success "Created $CronusHome\.env from template"
    } else {
        New-Item -ItemType File -Force -Path $cronusEnv | Out-Null
        Write-Success "Created $CronusHome\.env (empty)"
    }
} else {
    Write-Info "$CronusHome\.env already exists — keeping it"
}

# config.yaml
$cronusConfig = "$CronusHome\config.yaml"
if (-not (Test-Path $cronusConfig)) {
    $configExample = "$ScriptDir\cli-config.yaml.example"
    if (Test-Path $configExample) {
        Copy-Item $configExample $cronusConfig
        Write-Success "Created $CronusHome\config.yaml from template"
    }
}

# SOUL.md — write without BOM (PS 5.1 Set-Content -Encoding UTF8 adds a BOM
# which Cronus's prompt-injection scanner flags as a hidden unicode char).
$soulPath = "$CronusHome\SOUL.md"
if (-not (Test-Path $soulPath)) {
    $soulContent = @"
# Cronus Agent Persona

<!--
This file defines the agent's personality and tone.
The agent will embody whatever you write here.
Edit this to customize how Cronus communicates with you.

Examples:
  - "You are a warm, playful assistant who uses kaomoji occasionally."
  - "You are a concise technical expert. No fluff, just facts."
  - "You speak like a friendly coworker who happens to know everything."

This file is loaded fresh each message -- no restart needed.
Delete the contents (or this file) to use the default personality.
-->
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($soulPath, $soulContent, $utf8NoBom)
    Write-Success "Created $CronusHome\SOUL.md (edit to customize personality)"
}

Write-Success "Configuration directory ready: $CronusHome\"

# ============================================================================
# Seed bundled skills
# ============================================================================

Write-Info "Syncing bundled skills to $CronusHome\skills\ ..."

if (Test-Path $VenvPython) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $VenvPython "$ScriptDir\tools\skills_sync.py" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Skills synced to $CronusHome\skills\"
        } else {
            throw "skills_sync.py exited $LASTEXITCODE"
        }
    } catch {
        # Fallback: plain directory copy
        $bundledSkills = "$ScriptDir\skills"
        $userSkills    = "$CronusHome\skills"
        if (Test-Path $bundledSkills) {
            $hasSkills = Get-ChildItem $userSkills -Exclude ".bundled_manifest" -ErrorAction SilentlyContinue
            if (-not $hasSkills) {
                Copy-Item -Path "$bundledSkills\*" -Destination $userSkills -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Skills copied to $CronusHome\skills\"
            }
        }
    }
    $ErrorActionPreference = $prevEAP
}

# ============================================================================
# Done
# ============================================================================

Write-Host ""
Write-Host "[OK] Setup complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Open a new terminal (so the updated PATH takes effect)"
Write-Host ""
Write-Host "  2. Run the setup wizard to configure API keys:"
Write-Host "       cronus setup"
Write-Host ""
Write-Host "  3. Start chatting:"
Write-Host "       cronus"
Write-Host ""
Write-Host "Other commands:"
Write-Host "  cronus status            # Check configuration"
Write-Host "  cronus gateway install   # Install gateway service (messaging + cron)"
Write-Host "  cronus cron list         # View scheduled jobs"
Write-Host "  cronus doctor            # Diagnose issues"
Write-Host "  cronus dashboard         # Open web UI (all tabs work natively on Windows)"
Write-Host ""

if (-not $SkipSetup) {
    $answer = Read-Host "Would you like to run the setup wizard now? [Y/n]"
    if ($answer -eq "" -or $answer -match "^[Yy]") {
        Write-Host ""
        & $VenvPython -m cronus_cli.main setup
    }
}
