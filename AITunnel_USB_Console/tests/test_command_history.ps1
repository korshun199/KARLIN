param([string]$SourcePath, [string]$TestRoot)

# Проверяем чтение, сохранение и ограничение истории команд на Windows PowerShell.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AI_Console.ps1'
}
$tokens = $null # Токены проверяемого файла.
$parseErrors = $null # Ошибки разбора PowerShell.
$syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Ошибка синтаксиса: ' + ($parseErrors | Out-String)) }

foreach ($functionName in @('Initialize-CommandHistory', 'Add-CommandHistory')) {
    $definition = $syntaxTree.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
    }, $true)
    if ($null -eq $definition) { throw ('Не найдена функция ' + $functionName) }
    Invoke-Expression $definition.Extent.Text
}

$testRoot = $TestRoot # Отдельный путь позволяет проверить запись непосредственно на exFAT-флешке.
if ([string]::IsNullOrWhiteSpace($testRoot)) {
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('aitunnel-history-test-' + [Guid]::NewGuid().ToString('N'))
}
$script:SessionDirectory = Join-Path $testRoot 'sessions'
[void][System.IO.Directory]::CreateDirectory($script:SessionDirectory)
Initialize-CommandHistory
Add-CommandHistory -Text 'Первая команда'
Add-CommandHistory -Text 'Первая команда'
Add-CommandHistory -Text 'Вторая команда'
Initialize-CommandHistory
if ($script:CommandHistory.Count -ne 2) { throw 'История не прочиталась или повтор подряд не подавлен.' }
if ($script:CommandHistory[0] -ne 'Первая команда' -or $script:CommandHistory[1] -ne 'Вторая команда') { throw 'Нарушен порядок истории.' }
for ($index = 0; $index -lt 110; $index++) { Add-CommandHistory -Text ('Команда {0}' -f $index) }
Initialize-CommandHistory
if ($script:CommandHistory.Count -ne 100) { throw 'История не ограничена последними 100 строками.' }
if ($script:CommandHistory[$script:CommandHistory.Count - 1] -ne 'Команда 109') { throw 'Последняя команда не сохранилась.' }
Write-Host 'PASS: сохранение, повторное чтение, UTF-8 и ограничение истории до 100 строк'
