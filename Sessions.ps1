# Хранит историю каждой сессии в отдельном журнале на накопителе программы.
function Initialize-SessionStore {
    # Создаём каталог журналов и восстанавливаем последнюю выбранную сессию.
    $script:SessionDirectory = Join-Path $script:AppDirectory 'sessions'
    $script:SessionPointer = Join-Path $script:SessionDirectory 'current.txt'
    [void][System.IO.Directory]::CreateDirectory($script:SessionDirectory)
    if (Test-Path -LiteralPath $script:SessionPointer) {
        $id = [System.IO.File]::ReadAllText($script:SessionPointer).Trim()
        if ($id -notmatch '^[0-9a-f]{32}$') { throw 'Некорректный указатель сессии. Файлы не изменены.' }
        if (-not (Test-Path -LiteralPath (Join-Path $script:SessionDirectory ($id + '.jsonl')))) { throw 'Файл последней сессии не найден. Файлы не изменены.' }
        Open-Session -Id $id
    } else { New-Session }
}

function Add-SessionEvent {
    # Добавляем событие отдельной строкой и сразу сбрасываем запись на диск.
    param([Parameter(Mandatory=$true)][hashtable]$Event)
    $Event.time = [DateTimeOffset]::Now.ToString('o')
    $line = (ConvertTo-Json -InputObject $Event -Depth 30 -Compress) + "`n"
    $file = New-Object System.IO.FileStream($script:SessionPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $data = (New-Object System.Text.UTF8Encoding($false)).GetBytes($line)
        $file.Write($data, 0, $data.Length)
        $file.Flush($true)
    } finally { $file.Dispose() }
}

function New-Session {
    # Начинаем новый журнал, не удаляя предыдущие диалоги.
    $script:SessionId = [Guid]::NewGuid().ToString('N')
    $script:SessionPath = Join-Path $script:SessionDirectory ($script:SessionId + '.jsonl')
    $script:History.Clear()
    Add-SessionEvent @{ type='session'; model=$script:Model }
    [System.IO.File]::WriteAllText($script:SessionPointer, $script:SessionId, (New-Object System.Text.UTF8Encoding($false)))
}

function Open-Session {
    # Восстанавливаем завершённые обмены и последнюю модель выбранной сессии.
    param([Parameter(Mandatory=$true)][string]$Id)
    if ($Id -notmatch '^[0-9a-f]{32}$') { throw 'Некорректный идентификатор сессии.' }
    $path = Join-Path $script:SessionDirectory ($Id + '.jsonl')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Сессия не найдена.' }
    $restored = New-Object System.Collections.ArrayList
    $restoredModel = $script:Model
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { throw 'Повреждён журнал сессии; он не изменён.' }
        if (($event.type -eq 'session' -or $event.type -eq 'model') -and $event.model) { $restoredModel = [string]$event.model }
        if ($event.type -eq 'turn') {
            [void]$restored.Add(@{ role='user'; content=[string]$event.user })
            [void]$restored.Add(@{ role='assistant'; content=[string]$event.assistant })
        }
    }
    $script:History.Clear()
    foreach ($item in $restored) { [void]$script:History.Add($item) }
    while ($script:History.Count -gt $script:HistoryLimit) { $script:History.RemoveAt(0) }
    $script:Model = $restoredModel
    $script:SessionId = $Id
    $script:SessionPath = $path
    [System.IO.File]::WriteAllText($script:SessionPointer, $Id, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-SessionList {
    # Возвращаем журналы по времени изменения для выбора пользователем.
    return @(Get-ChildItem -LiteralPath $script:SessionDirectory -Filter '*.jsonl' -File | Sort-Object LastWriteTime -Descending)
}

function Show-SessionHistory {
    # Показываем завершённые реплики и ошибки без внутренних событий инструмента.
    foreach ($line in [System.IO.File]::ReadAllLines($script:SessionPath, [System.Text.Encoding]::UTF8)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $event = $line | ConvertFrom-Json -ErrorAction Stop
        switch ($event.type) {
            'turn' { Write-Host ("`nТы: {0}`nОтвет: {1}" -f $event.user,$event.assistant) }
            'error' { Write-Host ("`nОшибка: {0}" -f $event.message) }
        }
    }
}
