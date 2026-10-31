param([string]$SourcePath)

# Проверяем преобразование ошибок PowerShell без выполнения внешних команд.
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AI_Console.ps1' # Проверяемый файл консоли.
}
$tokens = $null # Токены синтаксического разбора.
$parseErrors = $null # Ошибки синтаксического разбора.
$syntaxTree = [System.Management.Automation.Language.Parser]::ParseFile($SourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ('Ошибка синтаксиса: ' + ($parseErrors | Out-String)) }
$definition = $syntaxTree.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-PowerShellErrorOutput'
}, $true) # Функция обработки ошибок из исходного файла.
if ($null -eq $definition) { throw 'Не найдена функция преобразования ошибок.' }
Invoke-Expression $definition.Extent.Text

$plain = 'Обычная ошибка' # Обычный текст не должен изменяться.
if ((ConvertFrom-PowerShellErrorOutput -Text $plain) -ne $plain) { throw 'Изменён обычный текст ошибки.' }

$xml = '#< CLIXML' + "`n" + '<Objs Version="1.1.0.1" xmlns="http://schemas.microsoft.com/powershell/2004/04"><S S="Error">Ошибка: файл не найден_x000D__x000A_</S><S S="Error">Строка 1_x000D__x000A_</S></Objs>' # Пример ошибки Windows PowerShell.
$decoded = ConvertFrom-PowerShellErrorOutput -Text $xml # Читаемое сообщение после преобразования.
if ($decoded -ne "Ошибка: файл не найден`r`nСтрока 1`r`n") { throw 'Некорректное преобразование CLIXML.' }

$malformed = '#< CLIXML' + "`n" + '<Objs><broken>' # Некорректный XML нельзя скрывать от пользователя.
if ((ConvertFrom-PowerShellErrorOutput -Text $malformed) -ne $malformed) { throw 'Потеряно некорректное исходное сообщение.' }
Write-Host 'PASS: обычная ошибка, CLIXML с кириллицей, повреждённый CLIXML.'
