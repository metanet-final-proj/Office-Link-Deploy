param(
    [switch]$WithOps
)

$composeFile = Join-Path $PSScriptRoot "docker-compose.yml"
$envFile = Join-Path $PSScriptRoot ".env"

if (-not (Test-Path -LiteralPath $envFile)) {
    throw "deploy/.env가 없습니다. .env.example을 복사한 뒤 GPU 서버 IP와 환경값을 확인해 주세요."
}

$arguments = @("compose", "--env-file", $envFile, "-f", $composeFile)
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
