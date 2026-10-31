param([string]$Directory, [string]$ExpectedId)
# Проверяем настоящий журнал с повторным запуском отдельного процесса.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'Sessions.ps1')
if (-not $Directory) {
    $Directory = Join-Path ([System.IO.Path]::GetTempPath()) ('aitunnel-session-test-' + [Guid]::NewGuid().ToString('N'))
}
$script:AppDirectory = $Directory
$script:History = New-Object System.Collections.ArrayList
$script:HistoryLimit = 20
$script:Model = 'gpt-6-luna'
Initialize-SessionStore
if ($ExpectedId) {
    if ($script:SessionId -ne $ExpectedId) { throw 'Последняя сессия не восстановилась.' }
    if ($script:History.Count -ne 2 -or $script:History[0].content -ne 'Привет' -or $script:History[1].content -ne 'Ответ') { throw 'Реплики после перезапуска не восстановились.' }
    if ($script:Model -ne 'test-model') { throw 'Модель не восстановилась.' }
    Write-Host 'PASS: восстановление после перезапуска'
    exit 0
}
$first = $script:SessionId
Add-SessionEvent @{type='pending';text='Привет'}
Add-SessionEvent @{type='tool_start';command='Get-Date'}
Add-SessionEvent @{type='tool';command='Get-Date';result='test result'}
Add-SessionEvent @{type='turn';user='Привет';assistant='Ответ';model='test-model'}
Add-SessionEvent @{type='model';model='test-model'}
$powershell = (Get-Process -Id $PID).Path
& $powershell -NoLogo -NoProfile -File $PSCommandPath -Directory $Directory -ExpectedId $first
if ($LASTEXITCODE -ne 0) { throw 'Ошибка теста отдельного процесса.' }
New-Session
if ($script:SessionId -eq $first -or $script:History.Count -ne 0) { throw 'Новая сессия не создана.' }
if (@(Get-SessionList).Count -ne 2) { throw 'Список сессий неверен.' }
Open-Session -Id $first
if ($script:History.Count -ne 2) { throw 'Переключение сессии не восстановило историю.' }
$events = @(Get-Content -LiteralPath $script:SessionPath -Encoding UTF8 | ForEach-Object { $_ | ConvertFrom-Json })
if (@($events | Where-Object { $_.type -eq 'tool' }).Count -ne 1) { throw 'Результат инструмента не сохранён.' }
try { Open-Session -Id '../invalid'; throw 'Недопустимый ID принят.' } catch { if ($_.Exception.Message -eq 'Недопустимый ID принят.') { throw } }
Write-Host 'PASS: новая сессия, переключение, журнал инструмента и проверка ID'
