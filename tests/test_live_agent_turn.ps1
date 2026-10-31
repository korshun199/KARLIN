param()

# Проверяем реальный цикл запросов консоли к провайдеру с безопасной имитацией локальной команды.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:AITUNNEL_API_KEY)) { throw 'Для проверки нужна переменная AITUNNEL_API_KEY.' }
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AI_Console.ps1' # Исходный файл консоли.
$tokens = $null # Токены синтаксического разбора.
$parseErrors = $null # Ошибки синтаксического разбора.
$syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Ошибка синтаксиса: ' + ($parseErrors | Out-String)) }

foreach ($functionName in @('Get-AssistantText', 'Invoke-ChatRequest', 'Invoke-AgentTurn')) {
    $definition = $syntaxTree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true) # Узел нужной функции из настоящего кода программы.
    if ($null -eq $definition) { throw ('Не найдена функция: ' + $functionName) }
    Invoke-Expression $definition.Extent.Text
}

function Invoke-LocalPowerShell {
    # Возвращаем контролируемый результат вместо выполнения команды модели.
    param([string]$Command)
    $script:ToolRuns++
    return @{ exit_code = 0; timed_out = $false; stdout = '2026-01-01 12:00'; stderr = '' }
}

$script:History = New-Object System.Collections.ArrayList # Изолированная история теста.
$script:SystemInstructions = 'Отвечай кратко. Выполняй явную просьбу вызвать run_powershell.'
$script:ToolRoundLimit = 4
$script:Model = 'gpt-6-luna'
$script:MaxTokens = 400
$script:TimeoutSeconds = 60
$script:BaseUrl = 'https://api.aitunnel.ru/v1'
$script:ToolRuns = 0
$script:ToolDefinitions = @(@{
    type = 'function'
    function = @{
        name = 'run_powershell'
        description = 'Запустить команду PowerShell по просьбе пользователя.'
        parameters = @{
            type = 'object'
            properties = @{ command = @{ type = 'string' } }
            required = @('command')
            additionalProperties = $false
        }
    }
})

$greeting = Invoke-AgentTurn -UserText 'Привет! Ответь одним словом, инструменты не нужны.' # Обычный ответ без инструмента.
if ([string]::IsNullOrWhiteSpace($greeting)) { throw 'Провайдер не вернул текст приветствия.' }
if ($script:ToolRuns -ne 0) { throw 'Для приветствия неожиданно вызван инструмент.' }
Write-Host 'PASS: реальный ответ gpt-6-luna на приветствие.'

$toolAnswer = Invoke-AgentTurn -UserText 'Вызови run_powershell с командой Get-Date и сообщи результат.' # Реальный цикл с подставным выполнением.
if ($script:ToolRuns -ne 1) { throw ('Ожидался один вызов инструмента, получено: ' + $script:ToolRuns) }
if ([string]::IsNullOrWhiteSpace($toolAnswer)) { throw 'После инструмента не получен итоговый ответ.' }
Write-Host 'PASS: реальный вызов инструмента и итоговый ответ gpt-6-luna.'
