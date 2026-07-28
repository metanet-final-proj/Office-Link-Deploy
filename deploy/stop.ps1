$composeFile = Join-Path $PSScriptRoot "docker-compose.yml"
$envFile = Join-Path $PSScriptRoot ".env"

& docker compose --env-file $envFile -f $composeFile --profile ops down
exit $LASTEXITCODE
