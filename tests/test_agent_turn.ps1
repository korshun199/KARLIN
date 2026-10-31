param([string]$SourcePath)

# Проверяем реальную функцию агента из консоли, заменяя только API и запуск команд.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AI_Console.ps1' # Проверяемый файл консоли по умолчанию.
}
$tokens = $null # Токены синтаксического разбора.
$parseErrors = $null # Ошибки синтаксического разбора.
$syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ('Ошибка синтаксиса консоли: ' + ($parseErrors | Out-String))
}

foreach ($functionName in @('Get-AssistantText', 'Invoke-AgentTurn')) {
    $definition = $syntaxTree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true) # Узел функции из реального исходного файла.
    if ($null -eq $definition) { throw ('Не найдена функция: ' + $functionName) }
    Invoke-Expression $definition.Extent.Text
}

function Invoke-ChatRequest {
    # Возвращаем заранее заданный ответ вместо сетевого запроса.
    param([object[]]$Messages)
    [void]$script:CapturedRequests.Add($Messages)
    if ($script:FakeResponses.Count -eq 0) { throw 'Лишний запрос к провайдеру.' }
    return $script:FakeResponses.Dequeue()
}

function Invoke-LocalPowerShell {
    # Имитируем результат инструмента, не выполняя команду на компьютере.
    param([string]$Command)
    $script:ToolRuns++
    return @{ exit_code = 0; timed_out = $false; stdout = 'mock'; stderr = '' }
}

function Reset-TestState {
    # Создаём независимую историю и очередь ответов для каждого случая.
    $script:History = New-Object System.Collections.ArrayList
    $script:CapturedRequests = New-Object System.Collections.ArrayList
    $script:FakeResponses = New-Object System.Collections.Queue
    $script:SystemInstructions = 'test'
    $script:ToolRoundLimit = 8
    $script:ToolRuns = 0
}

function Assert-Condition {
    # Останавливаем тест с понятной причиной, если условие не выполнено.
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function New-Response {
    # Создаём ответ той же структуры, что возвращает Chat Completions API.
    param([object]$Message)
    return @{ choices = @(@{ message = $Message }) }
}

foreach ($case in @('absent', 'null', 'empty')) {
    Reset-TestState
    $message = @{ content = 'Hello' } # Ответ с текстом и тремя вариантами отсутствия инструмента.
    if ($case -eq 'null') { $message.tool_calls = $null }
    if ($case -eq 'empty') { $message.tool_calls = @() }
    $script:FakeResponses.Enqueue((New-Response -Message $message))
    $answer = Invoke-AgentTurn -UserText 'Hello' # Ответ реальной функции агента.
    Assert-Condition ($answer -eq 'Hello') ('Не получен текстовый ответ: ' + $case)
    Assert-Condition ($script:CapturedRequests.Count -eq 1) ('Лишний запрос: ' + $case)
    Assert-Condition ($script:ToolRuns -eq 0) ('Ложный запуск инструмента: ' + $case)
    Write-Host ('PASS: обычный ответ, tool_calls=' + $case)
}

foreach ($case in @('existing-id', 'missing-id')) {
    Reset-TestState
    $call = @{ type = 'function'; function = @{ name = 'run_powershell'; arguments = '{"command":"Get-Date"}' } } # Поддельный вызов инструмента.
    if ($case -eq 'existing-id') { $call.id = 'call_original' }
    $script:FakeResponses.Enqueue((New-Response -Message @{ content = $null; tool_calls = @($call) }))
    $script:FakeResponses.Enqueue((New-Response -Message @{ content = 'Done' }))
    $answer = Invoke-AgentTurn -UserText 'Check the date' # Результат полной последовательности инструмента.
    Assert-Condition ($answer -eq 'Done') ('Нет итогового ответа: ' + $case)
    Assert-Condition ($script:ToolRuns -eq 1) ('Неверное число вызовов инструмента: ' + $case)
    Assert-Condition ($script:CapturedRequests.Count -eq 2) ('Неверное число запросов: ' + $case)
    $followup = $script:CapturedRequests[1] # Второй запрос, где должны совпадать два идентификатора.
    $assistant = @($followup | Where-Object { $_.role -eq 'assistant' })[-1]
    $tool = @($followup | Where-Object { $_.role -eq 'tool' })[-1]
    $assistantId = [string]$assistant.tool_calls[0].id
    Assert-Condition (-not [string]::IsNullOrWhiteSpace($assistantId)) ('Пустой ID: ' + $case)
    Assert-Condition ($assistantId -eq [string]$tool.tool_call_id) ('ID вызова и ответа различаются: ' + $case)
    if ($case -eq 'existing-id') { Assert-Condition ($assistantId -eq 'call_original') 'Изменён исходный ID.' }
    Write-Host ('PASS: вызов инструмента, ' + $case)
}
