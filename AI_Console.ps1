param()

# Останавливаем выполнение при ошибках, чтобы не отправить некорректный запрос.
$ErrorActionPreference = 'Stop'

# Переключаем консоль на UTF-8 для русского текста в Windows.
$utf8Encoding = [System.Text.UTF8Encoding]::new($false) # Кодировка без BOM для ввода и вывода.
[Console]::InputEncoding = $utf8Encoding
[Console]::OutputEncoding = $utf8Encoding

# Сохраняем пути к каталогу программы и её настройкам.
$script:AppDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:ConfigPath = Join-Path $script:AppDirectory 'config.json'
$script:AgentsPath = Join-Path $script:AppDirectory 'AGENTS.md'
$script:InstructionsPath = Join-Path $script:AppDirectory 'assistant_instructions.txt'

# Готовим память диалога, активную модель и список моделей провайдера.
$script:History = New-Object System.Collections.ArrayList
$script:AvailableModels = @()
$script:Model = ''
$script:BaseUrl = ''
$script:MaxTokens = 2048
$script:HistoryLimit = 20
$script:TimeoutSeconds = 180
$script:SystemInstructions = ''
$script:ToolRoundLimit = 8 # Ограничиваем число последовательных запросов инструмента в одном ответе.
$script:ToolTimeoutSeconds = 120 # Ограничиваем время выполнения одной команды.
$script:ToolOutputLimit = 12000 # Ограничиваем размер результата команды, отправляемого модели.
$script:ToolDefinitions = @(
    @{ # Описываем модели единственный локальный инструмент с полным доступом текущего пользователя.
        type = 'function'
        function = @{
            name = 'run_powershell'
            description = 'Выполняет произвольный скрипт Windows PowerShell 5.1 на этом компьютере от имени текущего пользователя. Команда запускается автоматически, без дополнительного подтверждения. Доступны файлы, процессы, программы и сеть в пределах прав пользователя.'
            parameters = @{
                type = 'object'
                properties = @{
                    command = @{ type = 'string'; description = 'Полная команда или скрипт Windows PowerShell для выполнения.' }
                }
                required = @('command')
                additionalProperties = $false
            }
        }
    }
)
$script:SlashCommands = @(
    '/help',
    '/commands',
    '/models',
    '/model',
    '/reset',
    '/exit'
)

function Read-ChatInput {
    # Читаем строку посимвольно и показываем подстановки для команд, начинающихся с косой черты.
    param(
        # Подпись перед строкой ввода.
        [Parameter(Mandatory = $true)][string]$Prompt
    )

    [Console]::Write($Prompt + '> ')
    $buffer = New-Object System.Text.StringBuilder # Текст, набранный пользователем.
    $promptRow = [Console]::CursorTop # Строка консоли, в которой находится приглашение.
    $inputColumn = [Console]::CursorLeft # Столбец начала пользовательского ввода.
    $suggestionRows = 0 # Количество строк списка, которые нужно стереть перед обновлением.
    $matches = @() # Команды, совпадающие с набранным префиксом.
    $selectedIndex = 0 # Индекс выделенной команды в списке совпадений.

    while ($true) {
        $keyInfo = [Console]::ReadKey($true) # Читаем клавишу, не печатая её автоматически.

        if ($keyInfo.Key -eq [ConsoleKey]::Enter) {
            $inputEndRow = [Console]::CursorTop # Запоминаем фактический конец строки, в том числе после переноса.
            $inputEndColumn = [Console]::CursorLeft # Столбец конца строки перед удалением подсказок.
            for ($row = 1; $row -le $suggestionRows; $row++) {
                $clearRow = $promptRow + $row
                if ($clearRow -lt [Console]::BufferHeight) {
                    [Console]::SetCursorPosition(0, $clearRow)
                    [Console]::Write((' ' * [Console]::WindowWidth))
                }
            }
            [Console]::SetCursorPosition($inputEndColumn, $inputEndRow)
            [Console]::WriteLine()
            return $buffer.ToString()
        }

        if ($keyInfo.Key -eq [ConsoleKey]::Backspace) {
            if ($buffer.Length -gt 0) {
                [void]$buffer.Remove($buffer.Length - 1, 1)
                [Console]::Write("`b `b")
            }
        } elseif ($keyInfo.Key -eq [ConsoleKey]::Escape) {
            if ($buffer.ToString().StartsWith([string]'/')) {
                [void]$buffer.Clear()
                [Console]::SetCursorPosition($inputColumn, $promptRow)
                [Console]::Write((' ' * ([Console]::WindowWidth - $inputColumn)))
                [Console]::SetCursorPosition($inputColumn, $promptRow)
            } else {
                continue
            }
        } elseif ($keyInfo.Key -eq [ConsoleKey]::Tab -and $matches.Count -gt 0) {
            [void]$buffer.Clear()
            [void]$buffer.Append([string]$matches[$selectedIndex])
            [Console]::SetCursorPosition($inputColumn, $promptRow)
            [Console]::Write((' ' * ([Console]::WindowWidth - $inputColumn)))
            [Console]::SetCursorPosition($inputColumn, $promptRow)
            [Console]::Write($buffer.ToString())
        } elseif ($keyInfo.Key -eq [ConsoleKey]::UpArrow -and $matches.Count -gt 0) {
            $selectedIndex = ($selectedIndex - 1 + $matches.Count) % $matches.Count
        } elseif ($keyInfo.Key -eq [ConsoleKey]::DownArrow -and $matches.Count -gt 0) {
            $selectedIndex = ($selectedIndex + 1) % $matches.Count
        } elseif (-not [char]::IsControl($keyInfo.KeyChar)) {
            [void]$buffer.Append($keyInfo.KeyChar)
            [Console]::Write($keyInfo.KeyChar)
        } else {
            continue
        }

        $inputEndRow = [Console]::CursorTop # Запоминаем конец введённого текста перед перерисовкой подсказок.
        $inputEndColumn = [Console]::CursorLeft # Запоминаем столбец конца текста перед перерисовкой.

        # Удаляем прежнюю подсказку перед построением актуального списка.
        for ($row = 1; $row -le $suggestionRows; $row++) {
            $clearRow = $promptRow + $row
            if ($clearRow -lt [Console]::BufferHeight) {
                [Console]::SetCursorPosition(0, $clearRow)
                [Console]::Write((' ' * [Console]::WindowWidth))
            }
        }
        $suggestionRows = 0
        $currentText = $buffer.ToString() # Текущий текст после обработки очередной клавиши.

        if ($currentText.StartsWith([string]'/')) {
            $matches = @($script:SlashCommands | Where-Object { $_.StartsWith($currentText, [StringComparison]::OrdinalIgnoreCase) })
            if ($matches.Count -gt 0) {
                $selectedIndex = [Math]::Min($selectedIndex, $matches.Count - 1)
                $rowText = New-Object System.Collections.ArrayList # Строки подсказок для вывода под приглашением.
                for ($index = 0; $index -lt $matches.Count; $index += 3) {
                    $lastIndex = [Math]::Min($index + 2, $matches.Count - 1)
                    $tokens = New-Object System.Collections.ArrayList # Команды, помещающиеся в текущую строку подсказок.
                    for ($itemIndex = $index; $itemIndex -le $lastIndex; $itemIndex++) {
                        $marker = if ($itemIndex -eq $selectedIndex) { '>' } else { ' ' }
                        [void]$tokens.Add(('{0}{1}' -f $marker, $matches[$itemIndex]))
                    }
                    [void]$rowText.Add(([string]::Join('   ', [string[]]$tokens.ToArray())))
                }

                [Console]::SetCursorPosition($inputEndColumn, $inputEndRow)
                [Console]::WriteLine()
                [Console]::ForegroundColor = [ConsoleColor]::DarkGray
                [Console]::Write('  Доступные команды:')
                [Console]::ResetColor()
                $suggestionRows++
                foreach ($line in $rowText) {
                    [Console]::WriteLine()
                    [Console]::ForegroundColor = [ConsoleColor]::Cyan
                    [Console]::Write('  ' + $line)
                    [Console]::ResetColor()
                    $suggestionRows++
                }
                [Console]::SetCursorPosition($inputEndColumn, $inputEndRow)
            } else {
                [Console]::SetCursorPosition($inputEndColumn, $inputEndRow)
                [Console]::WriteLine()
                [Console]::ForegroundColor = [ConsoleColor]::DarkGray
                [Console]::Write('  Нет совпадающих команд.')
                [Console]::ResetColor()
                $suggestionRows = 1
                [Console]::SetCursorPosition($inputEndColumn, $inputEndRow)
            }
        } else {
            $matches = @()
            $selectedIndex = 0
        }

        if (-not $currentText.StartsWith([string]'/')) {
            [Console]::SetCursorPosition($inputEndColumn, $inputEndRow)
        }
    }
}

function Show-Help {
    # Показываем доступные команды консоли.
    Write-Host ''
    Write-Host 'Команды чата:' -ForegroundColor Cyan
    Write-Host '  /помощь, /help       - показать эту справку'
    Write-Host '  /команды, /commands  - список системных и PowerShell-команд'
    Write-Host '  /модели, /models     - получить список моделей провайдера'
    Write-Host '  /модель, /model      - выбрать модель по ID или номеру'
    Write-Host '  /сброс, /reset       - очистить историю диалога'
    Write-Host '  /выход, /exit        - закрыть консоль'
    Write-Host ''
}

function Show-CommandList {
    # Показываем команды клиента и переведённые пояснения к системным командам Windows.
    Write-Host ''
    Write-Host 'Встроенные команды консоли:' -ForegroundColor Cyan
    Write-Host '  /помощь                 показать справку'
    Write-Host '  /команды                показать эту памятку'
    Write-Host '  /модели                 получить список моделей AITunnel'
    Write-Host '  /модель                 выбрать модель по номеру или ID'
    Write-Host '  /сброс                  очистить историю диалога'
    Write-Host '  /выход                  закрыть программу'
    Write-Host ''
    Write-Host 'Файлы и папки:' -ForegroundColor Cyan
    Write-Host '  Get-Location                         показать текущую папку'
    Write-Host '  Set-Location C:\путь                 перейти в папку'
    Write-Host '  Get-ChildItem C:\путь                показать файлы и папки'
    Write-Host '  Get-Content C:\путь\файл.txt         прочитать текстовый файл'
    Write-Host '  Set-Content C:\путь\файл.txt текст   записать текст в файл'
    Write-Host '  Copy-Item источник назначение        скопировать файл или папку'
    Write-Host '  Move-Item источник назначение        переместить файл или папку'
    Write-Host '  Remove-Item C:\путь                  УДАЛИТЬ файл или папку'
    Write-Host '  Select-String -Path ... -Pattern ...  найти текст в файлах'
    Write-Host ''
    Write-Host 'Система и программы:' -ForegroundColor Cyan
    Write-Host '  Get-ComputerInfo              общие сведения о компьютере'
    Write-Host '  Get-CimInstance Win32_...     получить сведения об устройстве Windows'
    Write-Host '  Get-Process                   показать запущенные процессы'
    Write-Host '  Stop-Process -Id номер        ЗАВЕРШИТЬ процесс'
    Write-Host '  Get-Service                   показать службы Windows'
    Write-Host '  Get-Command *имя*             найти команду PowerShell'
    Write-Host '  Get-Help имя-команды          открыть справку по команде'
    Write-Host '  Start-Process программа       запустить программу или файл'
    Write-Host '  whoami                        показать текущую учётную запись'
    Write-Host '  systeminfo                    показать подробные сведения Windows'
    Write-Host '  tasklist                      показать процессы в формате Windows'
    Write-Host ''
    Write-Host 'Сеть:' -ForegroundColor Cyan
    Write-Host '  Get-NetAdapter                показать сетевые адаптеры'
    Write-Host '  Get-NetIPAddress              показать IP-адреса'
    Write-Host '  Test-NetConnection адрес      проверить сетевое соединение'
    Write-Host '  Resolve-DnsName имя           проверить DNS-имя'
    Write-Host '  ipconfig /all                 подробные параметры TCP/IP'
    Write-Host '  ping адрес                    проверить доступность узла'
    Write-Host '  tracert адрес                 показать маршрут до узла'
    Write-Host ''
    Write-Host 'Диски и место:' -ForegroundColor Cyan
    Write-Host '  Get-Volume                    показать диски и разделы'
    Write-Host '  Get-PSDrive                   показать диски и доступное место'
    Write-Host ''
    Write-Host 'Это основные примеры, а не полный каталог: Windows PowerShell содержит много других команд.' -ForegroundColor DarkGray
    Write-Host 'Можно написать задачу обычными словами — агент сам выберет подходящие команды.'
    Write-Host ''
    Write-Host 'PowerShell запускается без дополнительного окна подтверждения от имени текущего пользователя.' -ForegroundColor Yellow
    Write-Host 'Правила AGENTS.md по опасным действиям сохраняются. Административные действия сработают только при повышенных правах программы.' -ForegroundColor Yellow
    Write-Host 'Результаты команд передаются провайдеру ИИ. Не поручай обработку секретных данных.' -ForegroundColor Yellow
    Write-Host ''
}

function Get-AssistantText {
    # Извлекаем текст ответа и учитываем строковый и блочный форматы content.
    param(
        # Ответ сервера, уже разобранный из JSON.
        [Parameter(Mandatory = $true)][object]$Response
    )

    $message = $Response.choices[0].message # Объект сообщения ассистента из ответа API.
    if ($null -eq $message -or $null -eq $message.content) {
        throw 'Ответ модели не содержит текста.'
    }

    if ($message.content -is [string]) {
        return [string]$message.content
    }

    $textParts = New-Object System.Collections.ArrayList # Собранные текстовые фрагменты ответа.
    foreach ($part in $message.content) { # Очередной фрагмент блочного ответа.
        if ($null -ne $part.text) {
            [void]$textParts.Add([string]$part.text)
        }
    }
    return [string]::Join("`n", [string[]]$textParts.ToArray())
}

function Invoke-ChatRequest {
    # Отправляем историю диалога и схему локального инструмента в Chat Completions API.
    param(
        # Сообщения диалога, включая промежуточные вызовы инструментов.
        [Parameter(Mandatory = $true)][object[]]$Messages
    )

    $payload = @{ # Поля совместимого запроса Chat Completions.
        model               = $script:Model
        max_tokens          = $script:MaxTokens
        messages            = $Messages
        tools               = $script:ToolDefinitions
        tool_choice         = 'auto'
        parallel_tool_calls = $false
    }
    $jsonBody = ConvertTo-Json -InputObject $payload -Depth 12 -Compress # Сериализуем вложенную схему инструмента без обрезки.
    $headers = @{ Authorization = ('Bearer ' + $env:AITUNNEL_API_KEY) } # Заголовок авторизации; секрет не выводим.
    $requestUri = $script:BaseUrl.TrimEnd('/') + '/chat/completions' # Адрес метода отправки сообщений.

    # TLS 1.2 нужен для HTTPS на штатном Windows PowerShell 5.1.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Передаём JSON строкой: charset=utf-8 кодирует тело штатными средствами PowerShell.
    return Invoke-RestMethod -UseBasicParsing -Uri $requestUri -Method Post `
        -Headers $headers -ContentType 'application/json; charset=utf-8' `
        -Body $jsonBody -TimeoutSec $script:TimeoutSeconds
}

function ConvertFrom-PowerShellErrorOutput {
    # Превращаем сериализованные ошибки Windows PowerShell в обычный читаемый текст.
    param(
        # Сырой текст стандартного потока ошибок дочернего процесса.
        [AllowEmptyString()][string]$Text
    )

    if ([string]::IsNullOrEmpty($Text) -or -not $Text.TrimStart().StartsWith('#< CLIXML')) {
        return $Text
    }

    try {
        $xmlStart = $Text.IndexOf('<Objs') # Начало XML после служебного заголовка PowerShell.
        if ($xmlStart -lt 0) { return $Text }
        $document = New-Object System.Xml.XmlDocument # Документ с сериализованными сообщениями об ошибках.
        $document.XmlResolver = $null # Не разрешаем загрузку внешних XML-сущностей.
        $document.LoadXml($Text.Substring($xmlStart))
        $errorNodes = $document.SelectNodes("//*[local-name()='S' and @S='Error']") # Текстовые записи потока ошибок.
        if ($errorNodes.Count -eq 0) { return $Text }
        $parts = New-Object System.Collections.ArrayList # Декодированные фрагменты сообщения.
        foreach ($node in $errorNodes) {
            [void]$parts.Add([System.Xml.XmlConvert]::DecodeName($node.InnerText))
        }
        return [string]::Concat([string[]]$parts.ToArray())
    } catch {
        # При неизвестном формате сохраняем исходный текст, чтобы не скрыть ошибку.
        return $Text
    }
}

function Invoke-LocalPowerShell {
    # Запускаем запрошенный моделью скрипт PowerShell от имени текущего пользователя.
    param(
        # Команда PowerShell, полученная в вызове инструмента.
        [Parameter(Mandatory = $true)][string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        throw 'Модель запросила пустую PowerShell-команду.'
    }

    $encodingSetup = @'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding
$ProgressPreference = 'SilentlyContinue'
'@ # Настраиваем UTF-8 и отключаем служебные индикаторы прогресса в дочернем процессе.
    $wrappedCommand = $encodingSetup + "`r`n" + $Command # Добавляем настройки перед командой модели.
    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrappedCommand)) # Кодируем команду для безопасной передачи процессу PowerShell.
    $powerShellPath = Join-Path $PSHOME 'powershell.exe' # Используем штатный Windows PowerShell 5.1.
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo # Параметры отдельного процесса команды.
    $startInfo.FileName = $powerShellPath
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encodedCommand
    $startInfo.WorkingDirectory = $script:AppDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.Encoding]::UTF8 # Читаем вывод дочернего PowerShell в той же кодировке.
    $startInfo.StandardErrorEncoding = [Text.Encoding]::UTF8 # Читаем сообщения об ошибках без потери кириллицы.
    [void]$startInfo.EnvironmentVariables.Remove('AITUNNEL_API_KEY') # Не передаём переменную API-ключа дочернему процессу.

    $process = New-Object System.Diagnostics.Process # Создаём отдельный процесс исполнения команды.
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw 'Не удалось запустить Windows PowerShell.'
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync() # Асинхронно читаем стандартный вывод команды.
        $stderrTask = $process.StandardError.ReadToEndAsync() # Асинхронно читаем ошибки команды.
        $completed = $process.WaitForExit($script:ToolTimeoutSeconds * 1000) # Ждём результат не дольше установленного лимита.
        if (-not $completed) {
            $process.Kill()
            [void]$process.WaitForExit()
            return @{ exit_code = $null; timed_out = $true; stdout = ''; stderr = 'Превышено время выполнения команды.' }
        }

        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        $stderr = ConvertFrom-PowerShellErrorOutput -Text $stderr # Расшифровываем ошибки Windows PowerShell, если они пришли в CLIXML.
        $secret = [string]$env:AITUNNEL_API_KEY # Секрет нужен только для удаления из результата команды.
        if (-not [string]::IsNullOrEmpty($secret)) {
            $stdout = $stdout.Replace($secret, '[СКРЫТЫЙ КЛЮЧ]')
            $stderr = $stderr.Replace($secret, '[СКРЫТЫЙ КЛЮЧ]')
        }
        if ($stdout.Length -gt $script:ToolOutputLimit) {
            $stdout = $stdout.Substring(0, $script:ToolOutputLimit) + "`n... [вывод обрезан]"
        }
        if ($stderr.Length -gt $script:ToolOutputLimit) {
            $stderr = $stderr.Substring(0, $script:ToolOutputLimit) + "`n... [вывод обрезан]"
        }
        return @{ exit_code = [int]$process.ExitCode; timed_out = $false; stdout = $stdout; stderr = $stderr }
    } finally {
        $process.Dispose()
    }
}

function Invoke-AgentTurn {
    # Выполняем полный цикл ответа модели с локальными вызовами PowerShell.
    param(
        # Новая реплика владельца для этого цикла.
        [Parameter(Mandatory = $true)][string]$UserText
    )

    $messages = New-Object System.Collections.ArrayList # Рабочая история одного запроса к модели.
    [void]$messages.Add(@{ role = 'system'; content = $script:SystemInstructions })
    foreach ($item in $script:History) {
        [void]$messages.Add($item)
    }
    [void]$messages.Add(@{ role = 'user'; content = $UserText })
    $toolRounds = 0 # Число уже выполненных циклов вызова инструмента.

    while ($true) {
        $response = Invoke-ChatRequest -Messages ([object[]]$messages.ToArray()) # Получаем очередной ответ или вызов инструмента.
        $assistantMessage = $response.choices[0].message # Сообщение модели в ответе API.
        # Отсутствующее поле tool_calls означает обычный текстовый ответ, а не массив с пустым вызовом.
        $toolCalls = @() # Подтверждённые непустые вызовы инструментов.
        if ($null -ne $assistantMessage.tool_calls) {
            $toolCalls = @($assistantMessage.tool_calls | Where-Object { $null -ne $_ })
        }
        if ($toolCalls.Count -eq 0) {
            return (Get-AssistantText -Response $response)
        }
        if ($toolRounds -ge $script:ToolRoundLimit) {
            throw 'Модель достигла предела последовательных вызовов PowerShell.'
        }

        $normalizedToolCalls = New-Object System.Collections.ArrayList # Вызовы инструмента с обязательными идентификаторами для API.
        foreach ($call in $toolCalls) {
            if ([string]::IsNullOrWhiteSpace([string]$call.function.name)) {
                throw 'Провайдер вернул вызов инструмента без имени функции.'
            }
            $callId = [string]$call.id # Идентификатор вызова, возвращённый провайдером.
            if ([string]::IsNullOrWhiteSpace($callId)) {
                $callId = 'call_local_' + [Guid]::NewGuid().ToString('N') # Локальный ID для согласования ответа при пустом ID провайдера.
                Write-Host 'Провайдер не вернул ID вызова; создан внутренний ID для продолжения диалога.' -ForegroundColor Yellow
            }

            $functionName = [string]$call.function.name # Имя функции, запрошенной моделью.
            $functionArguments = $call.function.arguments # Аргументы функции из ответа провайдера.
            if ($functionArguments -isnot [string]) {
                $functionArguments = ConvertTo-Json -InputObject $functionArguments -Depth 8 -Compress # Нормализуем аргументы к JSON-строке.
            }
            [void]$normalizedToolCalls.Add(@{
                id = $callId
                type = 'function'
                function = @{ name = $functionName; arguments = [string]$functionArguments }
            })
        }

        $assistantEntry = @{ role = 'assistant'; content = $assistantMessage.content; tool_calls = [object[]]$normalizedToolCalls.ToArray() } # Сохраняем согласованные ID вызовов и результата.
        if ($null -ne $assistantMessage.reasoning_details) {
            $assistantEntry.reasoning_details = $assistantMessage.reasoning_details
        }
        [void]$messages.Add($assistantEntry)

        foreach ($call in $normalizedToolCalls) {
            $toolName = [string]$call.function.name # Имя функции, которую запросила модель.
            if ($toolName -ne 'run_powershell') {
                $toolResult = @{ exit_code = 1; stdout = ''; stderr = ('Неизвестный инструмент: {0}' -f $toolName); timed_out = $false }
            } else {
                $arguments = $call.function.arguments | ConvertFrom-Json -ErrorAction Stop # Разбираем параметры вызова модели.
                $command = [string]$arguments.command # Команда PowerShell из параметров инструмента.
                $safeCommand = $command # Копируем команду для показа без секретов.
                if (-not [string]::IsNullOrEmpty([string]$env:AITUNNEL_API_KEY)) {
                    $safeCommand = $safeCommand.Replace([string]$env:AITUNNEL_API_KEY, '[СКРЫТЫЙ КЛЮЧ]')
                }
                Write-Host ''
                Write-Host 'Модель запускает PowerShell-команду:' -ForegroundColor Yellow
                Write-Host $safeCommand -ForegroundColor DarkYellow
                $toolResult = Invoke-LocalPowerShell -Command $command
                if ($toolResult.stdout) { Write-Host $toolResult.stdout -ForegroundColor Gray }
                if ($toolResult.stderr) { Write-Host $toolResult.stderr -ForegroundColor Red }
                Write-Host ('Код завершения: {0}' -f $toolResult.exit_code) -ForegroundColor DarkGray
            }

            $toolContent = ConvertTo-Json -InputObject $toolResult -Depth 4 -Compress # Формируем ответ инструмента для следующего шага API.
            [void]$messages.Add(@{ role = 'tool'; tool_call_id = [string]$call.id; content = $toolContent })
        }
        $toolRounds++
    }
}

function Save-CompletedTurn {
    # Сохраняем завершённый обмен и удаляем самые старые пары сообщений.
    param(
        # Реплика владельца.
        [Parameter(Mandatory = $true)][string]$UserText,
        # Финальный ответ модели.
        [Parameter(Mandatory = $true)][string]$AssistantText
    )

    [void]$script:History.Add(@{ role = 'user'; content = $UserText })
    [void]$script:History.Add(@{ role = 'assistant'; content = $AssistantText })
    while ($script:History.Count -gt $script:HistoryLimit) {
        $script:History.RemoveAt(0)
    }
}

function Get-ProviderModels {
    # Получаем список моделей через совместимую конечную точку /models.
    $requestUri = $script:BaseUrl.TrimEnd('/') + '/models' # Адрес списка моделей провайдера.
    $headers = @{ Authorization = ('Bearer ' + $env:AITUNNEL_API_KEY) } # Заголовок авторизации.
    # Запрашиваем полный ответ со списком доступных моделей.
    $response = Invoke-RestMethod -UseBasicParsing -Uri $requestUri -Method Get `
        -Headers $headers -TimeoutSec $script:TimeoutSeconds

    if ($null -eq $response.data) {
        throw 'Ответ провайдера не содержит списка моделей.'
    }

    $script:AvailableModels = @($response.data | ForEach-Object { [string]$_.id })
    if ($script:AvailableModels.Count -eq 0) {
        throw 'Провайдер вернул пустой список моделей.'
    }

    Write-Host ''
    for ($index = 0; $index -lt $script:AvailableModels.Count; $index++) {
        Write-Host ('{0,3}. {1}' -f ($index + 1), $script:AvailableModels[$index])
    }
    Write-Host ''
}

function Show-RequestError {
    # Показываем HTTP-статус, подробности провайдера и сетевую причину, не раскрывая ключ.
    param(
        # Ошибка, полученная при запросе к провайдеру.
        [Parameter(Mandatory = $true)][object]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception # Исключение запроса для сетевой диагностики.
    $statusCode = '' # HTTP-код, если провайдер успел ответить.
    $statusDescription = '' # Краткое пояснение HTTP-статуса.
    $errorText = [string]$exception.Message # Сообщение самого PowerShell или сетевого слоя.
    $responseBody = '' # Тело ответа, полученное от провайдера.
    $providerMessage = '' # Человекочитаемая ошибка из JSON-ответа провайдера.
    $providerCode = '' # Машиночитаемый код ошибки провайдера.
    $providerType = '' # Тип ошибки, если он указан провайдером.
    $requestId = '' # Идентификатор запроса для обращения в поддержку.
    $causeText = '' # Первопричина вложенной сетевой ошибки.
    $response = $null # HTTP-ответ может отсутствовать при сетевом сбое.

    # В Windows PowerShell текст ответа часто находится здесь, а не в Response.
    try {
        if ($null -ne $ErrorRecord.ErrorDetails -and
            -not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ErrorDetails.Message)) {
            $responseBody = [string]$ErrorRecord.ErrorDetails.Message
        }
    } catch {
        # Продолжаем диагностику по другим доступным свойствам ошибки.
    }

    # Извлекаем поля HTTP-ответа, поддерживая Windows PowerShell 5.1 и PowerShell 7.
    try {
        $response = $exception.Response
    } catch {
        # Для DNS, TLS и таймаута HTTP-ответа может не быть.
    }
    if ($null -ne $response) {
        try {
            if ($null -ne $response.StatusCode) {
                $statusCode = [string][int]$response.StatusCode
            }
        } catch {
            # Некоторые типы ответа не предоставляют числовой статус.
        }
        try {
            $statusDescription = [string]$response.StatusDescription
            if ([string]::IsNullOrWhiteSpace($statusDescription)) {
                $statusDescription = [string]$response.ReasonPhrase
            }
        } catch {
            # Для некоторых вариантов HTTP-ответа доступен только код.
        }

        # Сохраняем идентификатор запроса, если провайдер добавил его в заголовки.
        foreach ($headerName in @('x-request-id', 'request-id', 'cf-ray')) {
            if (-not [string]::IsNullOrWhiteSpace($requestId)) {
                break
            }
            try {
                $requestId = [string]$response.Headers[$headerName]
            } catch {
                # Отсутствующий заголовок не мешает показать остальные детали.
            }
        }

        # В PowerShell 7 тело читается из HttpResponseMessage.Content.
        try {
            $responseContent = $response.Content # Содержимое HTTP-ответа в PowerShell 7.
            if ($null -ne $responseContent) {
                $responseTask = $responseContent.ReadAsStringAsync() # Задача чтения тела ответа.
                $contentText = [string]$responseTask.GetAwaiter().GetResult() # Прочитанный текст ошибки.
                if (-not [string]::IsNullOrWhiteSpace($contentText)) {
                    $responseBody = $contentText
                }
            }
        } catch {
            # Если это не HttpResponseMessage, ниже пробуем обычный поток ответа.
        }

        # Windows PowerShell 5.1 предоставляет тело через GetResponseStream().
        if ([string]::IsNullOrWhiteSpace($responseBody)) {
            $reader = $null # Читатель потока, который нужно закрыть даже при ошибке.
            try {
                $responseStream = $response.GetResponseStream() # Поток HTTP-ответа в Windows PowerShell.
                if ($null -ne $responseStream) {
                    $reader = [System.IO.StreamReader]::new($responseStream)
                    $responseBody = $reader.ReadToEnd()
                }
            } catch {
                # Тело может быть уже прочитано PowerShell или недоступно.
            } finally {
                if ($null -ne $reader) {
                    $reader.Dispose()
                }
            }
        }
    }

    # Разбираем стандартный OpenAI-совместимый JSON и распространённые альтернативы.
    if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
        try {
            $providerObject = $responseBody | ConvertFrom-Json -ErrorAction Stop # Разобранное тело ответа.
            $providerError = $providerObject.error # Вложенная ошибка OpenAI-совместимого API.
            if ($null -ne $providerError) {
                if ($providerError -is [string]) {
                    $providerMessage = [string]$providerError
                } else {
                    $providerMessage = [string]$providerError.message
                    $providerCode = [string]$providerError.code
                    $providerType = [string]$providerError.type
                }
            }
            if ([string]::IsNullOrWhiteSpace($providerMessage)) {
                $providerMessage = [string]$providerObject.message
            }
            if ([string]::IsNullOrWhiteSpace($providerMessage)) {
                $providerMessage = [string]$providerObject.detail
            }
            if ([string]::IsNullOrWhiteSpace($providerCode)) {
                $providerCode = [string]$providerObject.code
            }
            if ([string]::IsNullOrWhiteSpace($providerType)) {
                $providerType = [string]$providerObject.type
            }
            if ([string]::IsNullOrWhiteSpace($requestId)) {
                $requestId = [string]$providerObject.request_id # Идентификатор иногда приходит в JSON.
            }
            if ([string]::IsNullOrWhiteSpace($requestId)) {
                $requestId = [string]$providerObject.requestId # Альтернативное имя идентификатора запроса.
            }
        } catch {
            # Неформатированный ответ всё равно будет показан ниже как текст.
        }
    }

    # Для ошибок подключения показываем базовое сообщение из цепочки исключений.
    try {
        $baseException = $exception.GetBaseException() # Самая глубокая причина исключения.
        if ($null -ne $baseException -and
            -not [string]::IsNullOrWhiteSpace([string]$baseException.Message) -and
            [string]$baseException.Message -ne $errorText) {
            $causeText = [string]$baseException.Message
        }
    } catch {
        # Неизвестный тип исключения не должен скрыть исходную ошибку.
    }

    # Маскируем ключ во всех выводимых полях, включая необработанное тело ответа.
    $sanitize = {
        param([string]$Text)
        $safeText = $Text # Текст для вывода после удаления возможного секрета.
        $apiKey = [string]$env:AITUNNEL_API_KEY # Ключ нужен только для маскировки, не для отображения.
        if (-not [string]::IsNullOrEmpty($safeText) -and
            -not [string]::IsNullOrEmpty($apiKey)) {
        $safeText = $safeText.Replace($apiKey, '[КЛЮЧ СКРЫТ]')
        }
        return $safeText
    }
    $errorText = [string](& $sanitize $errorText)
    $providerMessage = [string](& $sanitize $providerMessage)
    $providerCode = [string](& $sanitize $providerCode)
    $providerType = [string](& $sanitize $providerType)
    $statusDescription = [string](& $sanitize $statusDescription)
    $requestId = [string](& $sanitize $requestId)
    $causeText = [string](& $sanitize $causeText)
    $responseBody = [string](& $sanitize $responseBody)

    # Не даём необычно большому ответу занять весь экран консоли.
    $maxBodyLength = 3000 # Максимальная длина необработанного ответа провайдера.
    if ($responseBody.Length -gt $maxBodyLength) {
        $responseBody = $responseBody.Substring(0, $maxBodyLength) + "`n... [ответ сокращён]"
    }

    Write-Host ''
    if ($statusCode) {
        if ($statusDescription) {
            Write-Host ('Запрос не выполнен (HTTP {0} {1}).' -f $statusCode, $statusDescription) -ForegroundColor Red
        } else {
            Write-Host ('Запрос не выполнен (HTTP {0}).' -f $statusCode) -ForegroundColor Red
        }
    } else {
        Write-Host 'Ошибка произошла до получения HTTP-ответа.' -ForegroundColor Red
    }

    if ($providerMessage) {
        Write-Host ('Сообщение провайдера: {0}' -f $providerMessage) -ForegroundColor Red
    } elseif ($errorText) {
        Write-Host ('Ошибка: {0}' -f $errorText) -ForegroundColor Red
    }
    if ($providerType -or $providerCode) {
        Write-Host ('Данные провайдера: тип={0}; код={1}' -f $providerType, $providerCode) -ForegroundColor Yellow
    }
    if ($causeText) {
        Write-Host ('Причина сети или системы: {0}' -f $causeText) -ForegroundColor Yellow
    }
    if ($responseBody) {
        Write-Host 'Ответ провайдера:' -ForegroundColor DarkYellow
        Write-Host $responseBody -ForegroundColor DarkYellow
    }
    if ($requestId) {
        Write-Host ('Идентификатор запроса провайдера: {0}' -f $requestId) -ForegroundColor DarkGray
    }
    $safeModel = [string](& $sanitize $script:Model) # Модель, предварительно очищенная от секрета.
    $safeBaseUrl = [string](& $sanitize $script:BaseUrl) # Адрес API, предварительно очищенный от секрета.
    Write-Host ('Модель: {0} | API: {1}' -f $safeModel, $safeBaseUrl) -ForegroundColor DarkGray
    Write-Host 'Проверь ключ API, подключение к интернету, адрес API и ID модели.' -ForegroundColor Yellow
    Write-Host ''
}

# Проверяем ключ до чтения настроек и не печатаем его в терминал.
if ([string]::IsNullOrWhiteSpace($env:AITUNNEL_API_KEY) -or
    $env:AITUNNEL_API_KEY -eq 'PASTE_YOUR_AITUNNEL_KEY_HERE') {
    Write-Host 'Открой api_key.cmd и укажи ключ AITunnel в переменной AITUNNEL_API_KEY.' -ForegroundColor Red
    exit 1
}

# Загружаем JSON-настройки и выбираем файл системных инструкций.
if (-not (Test-Path -LiteralPath $script:ConfigPath -PathType Leaf)) {
    Write-Host 'Файл config.json не найден.' -ForegroundColor Red
    exit 1
}
$instructionsPath = $script:AgentsPath # Файл правил проекта имеет приоритет над общими инструкциями.
if (-not (Test-Path -LiteralPath $instructionsPath -PathType Leaf)) {
    $instructionsPath = $script:InstructionsPath
}
if (-not (Test-Path -LiteralPath $instructionsPath -PathType Leaf)) {
    Write-Host 'Не найден ни AGENTS.md, ни assistant_instructions.txt.' -ForegroundColor Red
    exit 1
}

$config = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json # Прочитанные настройки клиента.
$script:BaseUrl = [string]$config.base_url
$script:Model = [string]$config.model
$script:MaxTokens = [int]$config.max_tokens
$script:HistoryLimit = [int]$config.history_messages
$script:TimeoutSeconds = [int]$config.timeout_seconds
# Читаем чистую строку без дополнительных свойств файлового провайдера PowerShell.
$script:SystemInstructions = [System.IO.File]::ReadAllText($instructionsPath, [System.Text.Encoding]::UTF8)
$script:SystemInstructions += "`r`n`r`nЛокальный инструмент run_powershell доступен для работы с этим компьютером. Когда задача требует осмотра файлов, диагностики или выполнения действий на этом компьютере, используй его, а не выдумывай результат. Консоль запускает вызовы инструмента без отдельного всплывающего подтверждения, от имени текущего пользователя Windows. Строго соблюдай ограничения безопасности и правила подтверждения из AGENTS.md. Не утверждай, что получены права администратора, если это не подтверждено результатом команды."

# Проверяем обязательные настройки, чтобы ошибка была понятной до сетевого запроса.
if ([string]::IsNullOrWhiteSpace($script:BaseUrl) -or
    [string]::IsNullOrWhiteSpace($script:Model) -or
    $script:MaxTokens -lt 1 -or $script:HistoryLimit -lt 0 -or
    $script:TimeoutSeconds -lt 1) {
    Write-Host 'Проверь base_url, model, max_tokens, history_messages и timeout_seconds в config.json.' -ForegroundColor Red
    exit 1
}

# Выводим краткий статус запуска, не показывая секретные данные.
Clear-Host
Write-Host 'Консоль ИИ AITunnel' -ForegroundColor Cyan
Write-Host ('Модель: {0}' -f $script:Model) -ForegroundColor Green
Write-Host ('API: {0}' -f $script:BaseUrl) -ForegroundColor DarkGray
# Показываем активный файл правил и состояние локального инструмента.
Write-Host ('Правила: {0}' -f (Split-Path -Leaf $instructionsPath)) -ForegroundColor DarkGray
Write-Host 'Локальный инструмент PowerShell доступен агенту; команды выполняются от текущего пользователя.' -ForegroundColor Yellow
Write-Host 'Введи /помощь для справки. Эта консоль не связана с текущим чатом Codex.' -ForegroundColor DarkGray
Show-Help

# Обрабатываем сообщения и команды до выхода пользователя.
while ($true) {
    $userText = Read-ChatInput -Prompt 'Ты' # Очередная команда или реплика пользователя.
    if ([string]::IsNullOrWhiteSpace($userText)) {
        continue
    }

    switch -Regex ($userText.Trim()) {
        '^/(выход|exit)$' {
            return
        }
        '^/(помощь|help)$' {
            Show-Help
            continue
        }
        '^/(команды|commands)$' {
            Show-CommandList
            continue
        }
        '^/(сброс|reset)$' {
            $script:History.Clear()
            Write-Host 'История диалога очищена.' -ForegroundColor Green
            continue
        }
        '^/(модели|models)$' {
            try {
                Write-Host 'Загружаю список моделей...' -ForegroundColor DarkGray
                Get-ProviderModels
            } catch {
                Show-RequestError -ErrorRecord $_
            }
            continue
        }
        '^/(модель|model)$' {
            $modelChoice = Read-Host 'Введи ID модели или номер из списка /модели' # Выбор модели по ID или номеру.
            if ($modelChoice -match '^\d+$' -and $script:AvailableModels.Count -gt 0) {
                $modelIndex = [int]$modelChoice - 1 # Перевод номера из списка в индекс массива.
                if ($modelIndex -ge 0 -and $modelIndex -lt $script:AvailableModels.Count) {
                    $script:Model = $script:AvailableModels[$modelIndex]
                } else {
                    Write-Host 'Такого номера в списке нет.' -ForegroundColor Yellow
                    continue
                }
            } elseif (-not [string]::IsNullOrWhiteSpace($modelChoice)) {
                $script:Model = $modelChoice.Trim()
            } else {
                Write-Host 'Модель не изменена.' -ForegroundColor Yellow
                continue
            }
            Write-Host ('Выбрана модель: {0}' -f $script:Model) -ForegroundColor Green
            continue
        }
        default {
            try {
                Write-Host 'Жду ответ модели...' -ForegroundColor DarkGray
                $assistantText = Invoke-AgentTurn -UserText $userText # Ответ модели с выполнением её локальных команд.
                Save-CompletedTurn -UserText $userText -AssistantText $assistantText
                Write-Host ''
                Write-Host ('Ответ [{0}]:' -f $script:Model) -ForegroundColor Magenta
                Write-Host $assistantText
                Write-Host ''
            } catch {
                Show-RequestError -ErrorRecord $_
            }
        }
    }
}
