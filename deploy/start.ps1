param(
    [switch]$WithOps,
    [switch]$Harness,
    [switch]$ValidateOnly
)

$composeFile = Join-Path $PSScriptRoot "docker-compose.yml"
$harnessComposeFile = Join-Path $PSScriptRoot "docker-compose.harness.yml"
$envFile = Join-Path $PSScriptRoot ".env"

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "deploy/.env is missing. Copy .env.example and configure the deployment values."
}

function Read-DotEnvFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $values = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match "^\s*#" -or $line -notmatch "^\s*(?<name>[A-Z][A-Z0-9_]*)\s*=\s*(?<value>.*)$") {
            continue
        }

        $value = $Matches.value.Trim()
        if (
            ($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))
        ) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $values[$Matches.name] = $value
    }
    return $values
}

function Assert-DeploymentSecrets {
    param([Parameter(Mandatory = $true)][hashtable]$Values)

    $required = @(
        "ONPREM_LLM_BASE_URL",
        "ONPREM_LLM_API_KEY",
        "OPENAI_API_KEY",
        "AZURE_CLIENT_ID",
        "AZURE_CLIENT_SECRET",
        "JWT_SECRET",
        "OAUTH_JWT_KEY_ID",
        "OAUTH_JWT_PRIVATE_KEY_BASE64",
        "OAUTH_JWT_PUBLIC_KEY_BASE64",
        "CHAT_BACKEND_CLIENT_SECRET",
        "CHAT_BACKEND_WORKHUB_CLIENT_SECRET",
        "AI_AGENT_CLIENT_SECRET",
        "MCP_SERVER_CLIENT_SECRET",
        "WORKHUB_BACKEND_CLIENT_SECRET",
        "FINAL_POSTGRES_PASSWORD",
        "WORKHUB_POSTGRES_PASSWORD"
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $required) {
        $value = [string]$Values[$name]
        if (
            [string]::IsNullOrWhiteSpace($value) -or
            $value -match "^<.*>$" -or
            $value -match "^(change|replace|your|example)[-_].*"
        ) {
            $errors.Add("$name is not configured.")
        }
    }

    if ($Values["JWT_SECRET"] -and ([string]$Values["JWT_SECRET"]).Length -lt 32) {
        $errors.Add("JWT_SECRET must contain at least 32 characters.")
    }

    foreach ($name in @(
        "CHAT_BACKEND_CLIENT_SECRET",
        "CHAT_BACKEND_WORKHUB_CLIENT_SECRET",
        "AI_AGENT_CLIENT_SECRET",
        "MCP_SERVER_CLIENT_SECRET",
        "WORKHUB_BACKEND_CLIENT_SECRET"
    )) {
        if ($Values[$name] -and ([string]$Values[$name]).Length -lt 24) {
            $errors.Add("$name must contain at least 24 characters.")
        }
    }

    foreach ($name in @("OAUTH_JWT_PRIVATE_KEY_BASE64", "OAUTH_JWT_PUBLIC_KEY_BASE64")) {
        if (-not $Values[$name]) {
            continue
        }
        try {
            [void][Convert]::FromBase64String([string]$Values[$name])
        }
        catch {
            $errors.Add("$name must be valid Base64.")
        }
    }

    if ($errors.Count -gt 0) {
        $details = $errors | ForEach-Object { " - $_" }
        throw "Required deployment secrets are invalid:`n$($details -join "`n")"
    }
}

$deploymentEnv = Read-DotEnvFile $envFile
Assert-DeploymentSecrets $deploymentEnv

if ($ValidateOnly) {
    Write-Host "Deployment secret validation passed."
    return
}

$arguments = @("compose", "--env-file", $envFile, "-f", $composeFile)
if ($Harness) {
    if (-not (Test-Path -LiteralPath $harnessComposeFile)) {
        throw "Harness compose file not found: $harnessComposeFile"
    }
    $arguments += @("-f", $harnessComposeFile)
}
if ($WithOps) {
    $arguments += @("--profile", "ops")
}
$arguments += @("up", "-d", "--build", "--remove-orphans")

& docker @arguments
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "Office-Link: http://localhost"
if ($WithOps) {
    Write-Host "Kafka UI:   http://localhost:18090"
}
if ($Harness) {
    Write-Host "Harness AI: http://127.0.0.1:8000"
    Write-Host "Harness OAuth: http://127.0.0.1:8080/oauth2/token"
}
