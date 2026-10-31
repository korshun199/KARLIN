param([string]$SourcePath)

# Проверяем разбор файла и точное объединение многострочного сообщения.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AI_Console.ps1'
}
$tokens = $null # Токены проверяемого PowerShell-файла.
$parseErrors = $null # Ошибки синтаксического разбора.
$syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Ошибка синтаксиса: ' + ($parseErrors | Out-String)) }

$definition = $syntaxTree.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Convert-MultilineLinesToText'
}, $true)
if ($null -eq $definition) { throw 'Не найдена функция Convert-MultilineLinesToText.' }
Invoke-Expression $definition.Extent.Text

$actual = Convert-MultilineLinesToText -Lines @('Первая строка', '', 'третья строка — длинный текст')
$expected = "Первая строка`r`n`r`nтретья строка — длинный текст"
if ($actual -cne $expected) { throw 'Строки или пустая строка объединяются неверно.' }
if ($syntaxTree.Extent.Text -notmatch "'/multi'") { throw 'Команда /multi отсутствует в подсказках.' }
Write-Host 'PASS: многострочный текст и пустые строки сохраняются без потерь'
