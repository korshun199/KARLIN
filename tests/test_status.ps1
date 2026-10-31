param([string]$SourcePath)

# Проверяем /status без реального запроса и без настоящего API-ключа.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AI_Console.ps1'
}
$tokens = $null # Токены исходного PowerShell-файла.
$parseErrors = $null # Ошибки синтаксического разбора.
$syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Ошибка синтаксиса: ' + ($parseErrors | Out-String)) }

$script:StatusRequests = New-Object System.Collections.ArrayList # Адреса и безопасные заголовки тестовых запросов.
$script:StatusOutput = New-Object System.Collections.ArrayList # Текст, который функция показывает пользователю.
$script:BaseUrl = 'https://api.aitunnel.ru/v1' # Тестовый адрес провайдера.
$script:TimeoutSeconds = 10 # Короткий предел времени для тестового окружения.
$env:AITUNNEL_API_KEY = 'test-key-not-real' # Фиктивный ключ, никогда не отправляемый в сеть.

function Invoke-RestMethod {
    # Подменяем сетевой вызов заранее известными ответами AITunnel.
    param([string]$Uri, [string]$Method, [hashtable]$Headers, [int]$TimeoutSec, [switch]$UseBasicParsing)
    [void]$script:StatusRequests.Add([pscustomobject]@{ Uri=$Uri; Method=$Method; Authorization=$Headers.Authorization })
    if ($Uri -like '*/aitunnel/balance') {
        return [pscustomobject]@{ balance=1234.5; budget=25.75 }
    }
    if ($Uri -like '*/aitunnel/stats/summary') {
        return [pscustomobject]@{
            today_spend=12.5; today_requests=7; month_spend=125.8; month_requests=42
            avg_daily_spend=4.19; top_model_by_spend='test-model'; top_model_by_spend_value=80.2
            top_model_by_requests='test-model'; top_model_by_requests_value=30
        }
    }
    throw ('Неожиданный адрес тестового запроса: ' + $Uri)
}

function Write-Host {
    # Сохраняем консольный вывод для проверок без показа тестовых данных.
    param([Parameter(Position=0)][AllowNull()][object]$Object, [System.ConsoleColor]$ForegroundColor, [switch]$NoNewline)
    [void]$script:StatusOutput.Add([string]$Object)
}

function Show-RequestError {
    # Считаем любой вызов обработчика ошибок провала теста.
    param([object]$ErrorRecord)
    throw 'В тесте статуса неожиданно вызван обработчик ошибки.'
}

foreach ($functionName in @('Invoke-AitunnelGet', 'Show-AitunnelStatus')) {
    $definition = $syntaxTree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if ($null -eq $definition) { throw ('Не найдена функция ' + $functionName + '.') }
    Invoke-Expression $definition.Extent.Text
}

if ($syntaxTree.Extent.Text -notmatch "'\^/status\$'") { throw 'Обработчик команды /status отсутствует.' }
Show-AitunnelStatus
if ($script:StatusRequests.Count -ne 2) { throw 'Команда /status должна выполнить ровно два GET-запроса.' }
if ($script:StatusRequests[0].Uri -ne 'https://api.aitunnel.ru/v1/aitunnel/balance') { throw 'Запрос баланса собран неверно.' }
if ($script:StatusRequests[1].Uri -ne 'https://api.aitunnel.ru/v1/aitunnel/stats/summary') { throw 'Запрос статистики собран неверно.' }
foreach ($request in $script:StatusRequests) {
    if ($request.Method -ne 'Get' -or $request.Authorization -ne 'Bearer test-key-not-real') { throw 'Метод или заголовок запроса неверен.' }
}
$outputText = [string]::Join("`n", [string[]]$script:StatusOutput.ToArray()) # Собранный вывод функции.
foreach ($expectedText in @('Баланс аккаунта:', 'Остаток бюджета ключа:', 'Сегодня:', 'За 30 дней:', 'Наибольшие расходы:')) {
    if ($outputText -notmatch [regex]::Escape($expectedText)) { throw ('В выводе отсутствует поле: ' + $expectedText) }
}
Write-Output 'PASS: баланс, бюджет, статистика, URL и Bearer-заголовки проверены на фиктивных ответах'
