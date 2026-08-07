param(
    [switch]$InstallPythonDependencies,
    [switch]$SkipJava,
    [switch]$SkipPython
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

function Invoke-InDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Command
    )

    Push-Location $Path
    try {
        & $Command
    }
    finally {
        Pop-Location
    }
}

function Assert-NativeCommandSucceeded {
    param([Parameter(Mandatory = $true)][string]$Description)

    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Get-VenvPython {
    param([Parameter(Mandatory = $true)][string]$ProjectPath)

    $python = Join-Path $ProjectPath ".venv\Scripts\python.exe"
    if (-not (Test-Path $python)) {
        throw "Python virtual environment was not found: $python"
    }

    try {
        & $python --version *> $null
    }
    catch {
        throw "Python virtual environment is invalid. Recreate it before running coverage: $ProjectPath\.venv"
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Python virtual environment is invalid. Recreate it before running coverage: $ProjectPath\.venv"
    }

    return $python
}

function Repair-PydanticCoreIfNeeded {
    param([Parameter(Mandatory = $true)][string]$Python)

    try {
        & $Python -c "import pydantic_core" *> $null
        if ($LASTEXITCODE -eq 0) {
            return
        }
    }
    catch {
        # The environment can contain a wheel built for a different Python ABI.
    }

    Write-Host "Repairing pydantic-core for the active Python interpreter" -ForegroundColor Yellow
    $requirement = & $Python -c "from importlib.metadata import requires; print(next(item for item in requires('pydantic') if item.lower().startswith('pydantic-core==')))"
    Assert-NativeCommandSucceeded "Resolving the pydantic-core version"

    & $Python -m pip install --force-reinstall --no-cache-dir $requirement
    Assert-NativeCommandSucceeded "Reinstalling pydantic-core"
}

function Set-EphemeralOAuthSigningKeys {
    if ($env:OAUTH_JWT_PRIVATE_KEY_BASE64 -and $env:OAUTH_JWT_PUBLIC_KEY_BASE64) {
        return
    }

    $generator = Join-Path $PSScriptRoot "GenerateOAuthTestKeys.java"
    $keys = @(& java $generator)
    Assert-NativeCommandSucceeded "Generating ephemeral OAuth signing keys"
    if ($keys.Count -ne 2) {
        throw "Ephemeral OAuth key generator returned an unexpected result."
    }

    $env:OAUTH_JWT_KEY_ID = "coverage-ephemeral-key"
    $env:OAUTH_JWT_PRIVATE_KEY_BASE64 = $keys[0]
    $env:OAUTH_JWT_PUBLIC_KEY_BASE64 = $keys[1]
}

if (-not $SkipJava) {
    if (-not $env:CHAT_BACKEND_CLIENT_SECRET) {
        $env:CHAT_BACKEND_CLIENT_SECRET = "coverage-chat-secret"
    }
    if (-not $env:AI_AGENT_CLIENT_SECRET) {
        $env:AI_AGENT_CLIENT_SECRET = "coverage-ai-secret"
    }
    if (-not $env:MCP_SERVER_CLIENT_SECRET) {
        $env:MCP_SERVER_CLIENT_SECRET = "coverage-mcp-secret"
    }
    if (-not $env:WORKHUB_BACKEND_CLIENT_SECRET) {
        $env:WORKHUB_BACKEND_CLIENT_SECRET = "coverage-workhub-secret"
    }
    if (-not $env:CHAT_BACKEND_WORKHUB_CLIENT_SECRET) {
        $env:CHAT_BACKEND_WORKHUB_CLIENT_SECRET = "coverage-chat-workhub-secret"
    }
    if (-not $env:SPRING_DATASOURCE_PASSWORD) {
        $env:SPRING_DATASOURCE_PASSWORD = "coverage-database-secret"
    }
    if (-not $env:JWT_SECRET) {
        $env:JWT_SECRET = "coverage-jwt-secret-at-least-32-characters"
    }
    if (-not $env:AZURE_CLIENT_ID) {
        $env:AZURE_CLIENT_ID = "coverage-azure-client"
    }
    if (-not $env:AZURE_CLIENT_SECRET) {
        $env:AZURE_CLIENT_SECRET = "coverage-azure-secret"
    }
    if (-not $env:LOG_KAFKA_ENABLED) {
        $env:LOG_KAFKA_ENABLED = "false"
    }

    Set-EphemeralOAuthSigningKeys

    Write-Host "`n[1/4] Final Backend - JUnit + JaCoCo" -ForegroundColor Cyan
    Invoke-InDirectory (Join-Path $root "workspace-Final-Backend") {
        .\gradlew.bat clean test jacocoTestReport --console=plain
        Assert-NativeCommandSucceeded "Final Backend coverage"
    }

    Write-Host "`n[2/4] Workhub Backend - JUnit + JaCoCo" -ForegroundColor Cyan
    Invoke-InDirectory (Join-Path $root "workspace-Workhub-Backend") {
        .\gradlew.bat clean test jacocoTestReport --console=plain
        Assert-NativeCommandSucceeded "Workhub Backend coverage"
    }
}

if (-not $SkipPython) {
    $aiPath = Join-Path $root "workspace-Final-AI"
    $mcpPath = Join-Path $root "workspace-mcp-server"
    $aiPython = Get-VenvPython $aiPath
    $mcpPython = Get-VenvPython $mcpPath

    if ($InstallPythonDependencies) {
        Write-Host "`nInstalling AI Agent coverage dependencies" -ForegroundColor DarkCyan
        & $aiPython -m pip install -r (Join-Path $aiPath "requirements-dev.txt")
        Assert-NativeCommandSucceeded "Installing AI Agent coverage dependencies"
        Repair-PydanticCoreIfNeeded $aiPython

        Write-Host "`nInstalling MCP coverage dependencies" -ForegroundColor DarkCyan
        & $mcpPython -m pip install -e "${mcpPath}[development]"
        Assert-NativeCommandSucceeded "Installing MCP coverage dependencies"
        Repair-PydanticCoreIfNeeded $mcpPython
    }

    Write-Host "`n[3/4] AI Agent - pytest + pytest-cov" -ForegroundColor Cyan
    Invoke-InDirectory $aiPath {
        & $aiPython -m pytest -m "not integration" `
            --cov=orchestrator_agent `
            --cov-branch `
            --cov-report=term-missing `
            --cov-report=html:build/coverage/html `
            --cov-report=xml:build/coverage/coverage.xml
        Assert-NativeCommandSucceeded "AI Agent coverage"
    }

    Write-Host "`n[4/4] MCP Server - pytest + pytest-cov" -ForegroundColor Cyan
    Invoke-InDirectory $mcpPath {
        & $mcpPython -m pytest -m "not integration" `
            --cov=app `
            --cov-branch `
            --cov-report=term-missing `
            --cov-report=html:build/coverage/html `
            --cov-report=xml:build/coverage/coverage.xml
        Assert-NativeCommandSucceeded "MCP Server coverage"
    }
}

Write-Host "`nCoverage reports" -ForegroundColor Green
Write-Host "Final Backend : $root\workspace-Final-Backend\build\reports\jacoco\test\html\index.html"
Write-Host "Workhub Backend: $root\workspace-Workhub-Backend\build\reports\jacoco\test\html\index.html"
Write-Host "AI Agent      : $root\workspace-Final-AI\build\coverage\html\index.html"
Write-Host "MCP Server    : $root\workspace-mcp-server\build\coverage\html\index.html"
