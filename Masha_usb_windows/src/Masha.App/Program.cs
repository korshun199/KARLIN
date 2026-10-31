using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Masha.App;

internal static class Program
{
    // Запускаем интерфейс в однопоточном режиме Windows Forms.
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--self-test") return SelfTest.Run(args[1]);
        if (args.Length == 2 && args[0] == "--api-test") return SelfTest.RunApi(args[1]);
        if (args.Length != 0) return 1;
        ApplicationConfiguration.Initialize();
        try { Log.Write("Запуск окна"); Application.Run(new MainWindow()); Log.Write("Окно закрыто"); return 0; }
        catch (Exception ex) { Log.Write("Ошибка запуска: " + ex.GetType().Name); MessageBox.Show(ex.Message, "Ошибка запуска", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
    }
}

// Журнал содержит только служебные статусы без ключей и текста сообщений.
internal static class Log
{
    public static void Write(string message)
    {
        try { File.AppendAllText(Path.Combine(AppContext.BaseDirectory, "masha.log"), $"{DateTimeOffset.Now:O} {message}\n", new System.Text.UTF8Encoding(true)); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
}

// Настройки сохраняются рядом с программой и не содержат ключ.
internal sealed class Settings
{
    public string BaseUrl { get; set; } = "https://api.aitunnel.ru/v1";
    public string Model { get; set; } = "gpt-6-luna";
    public string TranscriptionModel { get; set; } = "whisper-1";
    public string SpeechModel { get; set; } = "gpt-4o-mini-tts";
    public string Voice { get; set; } = "alloy";
    public string SpeechFormat { get; set; } = "mp3";
}

internal sealed record SpeechOptions(string[] Voices, string[] Formats);
internal sealed record ChatOutcome(string Text, string[] Commands);

internal sealed record Turn(string User, string Assistant, string[] Attachments);

// Загружаем локальный список моделей, подходящих для чат-интерфейса приложения.
internal static class ChatModelCatalog
{
    // Читаем встроенный в EXE список ID, обновляемый из открытого каталога AITunnel.
    public static string[] Read()
    {
        using Stream stream = typeof(ChatModelCatalog).Assembly.GetManifestResourceStream("Masha.App.chat_models.json")
            ?? throw new FileNotFoundException("В EXE не встроен каталог чат-моделей chat_models.json.");
        using JsonDocument document = JsonDocument.Parse(stream);
        JsonElement models = document.RootElement.GetProperty("models");
        if (models.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Список чат-моделей имеет неверный формат.");
        string[] ids = models.EnumerateArray()
            .Select(item => item.GetString() ?? "")
            .Where(id => id.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .OrderBy(id => id, StringComparer.Ordinal)
            .ToArray();
        if (ids.Length == 0) throw new InvalidDataException("Список совместимых чат-моделей пуст.");
        return ids;
    }
}

// Отдельный JSONL-журнал позволяет продолжить диалог после перезапуска.
internal sealed class SessionStore
{
    private readonly string directory;
    public string Id { get; private set; } = "";
    public List<Turn> Turns { get; } = [];
    public string PathName => Path.Combine(directory, Id + ".jsonl");

    public SessionStore(string? root = null)
    {
        directory = Path.Combine(root ?? AppContext.BaseDirectory, "sessions");
        Directory.CreateDirectory(directory);
        string pointer = Path.Combine(directory, "current.txt");
        if (File.Exists(pointer)) Open(File.ReadAllText(pointer).Trim());
        else New();
    }

    // Создаём новый журнал с уникальным именем и не заменяем старые файлы.
    public void New()
    {
        string id = Guid.NewGuid().ToString("N");
        string path = Path.Combine(directory, id + ".jsonl");
        using (File.Create(path)) { }
        Id = id;
        Turns.Clear();
        Append(new { type = "session", model = "gpt-6-luna" });
        File.WriteAllText(Path.Combine(directory, "current.txt"), id);
    }

    // Читаем журнал целиком до изменения текущего состояния.
    public void Open(string id)
    {
        if (id.Length != 32 || id.Any(c => !Uri.IsHexDigit(c))) throw new InvalidDataException("Неверный идентификатор диалога.");
        string path = Path.Combine(directory, id + ".jsonl");
        var restored = new List<Turn>();
        foreach (string line in File.ReadLines(path))
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            using JsonDocument document = JsonDocument.Parse(line);
            JsonElement item = document.RootElement;
            if (item.TryGetProperty("type", out var type) && type.GetString() == "turn")
            {
                string[] files = item.TryGetProperty("attachments", out var list) && list.ValueKind == JsonValueKind.Array
                    ? list.EnumerateArray().Select(file => file.GetString() ?? "").Where(file => file.Length > 0).ToArray() : [];
                restored.Add(new Turn(item.GetProperty("user").GetString() ?? "", item.GetProperty("assistant").GetString() ?? "", files));
            }
        }
        Id = id;
        Turns.Clear();
        Turns.AddRange(restored);
        File.WriteAllText(Path.Combine(directory, "current.txt"), id);
    }

    // Записываем завершённую пару сообщений одной строкой с принудительным сбросом.
    public void Add(string user, string assistant, string[] attachments)
    {
        Append(new { type = "turn", user, assistant, attachments });
        Turns.Add(new Turn(user, assistant, attachments));
    }

    private void Append(object value)
    {
        byte[] bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(value) + "\n");
        using var stream = new FileStream(PathName, FileMode.Append, FileAccess.Write, FileShare.Read);
        stream.Write(bytes);
        stream.Flush(true);
    }

    public IEnumerable<string> List() => Directory.EnumerateFiles(directory, "*.jsonl")
        .OrderByDescending(File.GetLastWriteTimeUtc).Select(path => System.IO.Path.GetFileNameWithoutExtension(path));
}

// Обмен с поставщиком выполняется асинхронно; ключ передаётся в заголовке.
internal sealed class ProviderClient
{
    private readonly HttpClient http;
    private readonly string url;
    private readonly string key;

    public ProviderClient(string url, string key, HttpMessageHandler? handler = null)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
            throw new ArgumentException("Адрес API должен начинаться с https://");
        if (string.IsNullOrWhiteSpace(key)) throw new ArgumentException("Укажите API-ключ в настройках.");
        this.url = url.TrimEnd('/');
        this.key = key.Trim();
        http = handler is null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = TimeSpan.FromSeconds(180);
    }

    // Возвращаем текст ответа или понятную ошибку HTTP без ключа.
    private async Task<string> Request(HttpMethod method, string endpoint, object? body, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(method, url + endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        if (body is not null) request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request, cancellation);
        string text = await response.Content.ReadAsStringAsync(cancellation);
        if (!response.IsSuccessStatusCode)
            throw new InvalidOperationException($"Ошибка сервера HTTP {(int)response.StatusCode}: {text.Replace(key, "[скрыто]")}");
        return text;
    }

    public async Task<string[]> Models(CancellationToken cancellation)
    {
        using var document = JsonDocument.Parse(await Request(HttpMethod.Get, "/models", null, cancellation));
        var catalog = new HashSet<string>(ChatModelCatalog.Read(), StringComparer.Ordinal);
        return document.RootElement.GetProperty("data").EnumerateArray()
            .Select(item => item.GetProperty("id").GetString() ?? "")
            .Where(id => id.Length > 0 && catalog.Contains(id))
            .Distinct(StringComparer.Ordinal)
            .OrderBy(id => id, StringComparer.Ordinal)
            .ToArray();
    }

    public async Task<string> Balance(CancellationToken cancellation)
    {
        using var document = JsonDocument.Parse(await Request(HttpMethod.Get, "/aitunnel/balance", null, cancellation));
        return document.RootElement.TryGetProperty("balance", out var balance) ? balance.ToString() : "нет данных";
    }

    // Сводим баланс и расходы ключа в короткий экран состояния.
    public async Task<string> Status(CancellationToken cancellation)
    {
        using var balanceDoc = JsonDocument.Parse(await Request(HttpMethod.Get, "/aitunnel/balance", null, cancellation));
        using var statsDoc = JsonDocument.Parse(await Request(HttpMethod.Get, "/aitunnel/stats/summary", null, cancellation));
        JsonElement balance = balanceDoc.RootElement, stats = statsDoc.RootElement;
        string value(string name) => stats.TryGetProperty(name, out var item) ? item.ToString() : "—";
        string accountBalance = balance.TryGetProperty("balance", out var amount) ? amount.ToString() : "—";
        string budget = balance.TryGetProperty("budget", out var limit) ? limit.ToString() : "не задан";
        return $"Баланс: {accountBalance} ₽\nБюджет ключа: {budget}\nСегодня: {value("today_spend")} ₽; запросов {value("today_requests")}\nЗа 30 дней: {value("month_spend")} ₽; запросов {value("month_requests")}\nСредний расход за день: {value("avg_daily_spend")} ₽";
    }

    // Читаем открытый каталог аудиомоделей без передачи API-ключа.
    public async Task<string[]> AudioModels(string kind, CancellationToken cancellation)
    {
        string url = kind == "transcriptions" ? "https://api.aitunnel.ru/public/aitunnel/models/transcriptions" : "https://api.aitunnel.ru/public/aitunnel/models/speech";
        using var document = JsonDocument.Parse(await http.GetStringAsync(url, cancellation));
        return document.RootElement.EnumerateObject().Select(item => item.Name).OrderBy(name => name).ToArray();
    }

    // Получаем доступные голоса и форматы именно выбранной модели синтеза.
    public async Task<SpeechOptions> SpeechModelOptions(string model, CancellationToken cancellation)
    {
        using var document = JsonDocument.Parse(await http.GetStringAsync("https://api.aitunnel.ru/public/aitunnel/models/speech", cancellation));
        if (!document.RootElement.TryGetProperty(model, out var item)) throw new InvalidDataException("Модель синтеза отсутствует в каталоге.");
        string[] values(string name) => item.TryGetProperty(name, out var list) && list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Select(value => value.GetString() ?? "").Where(value => value.Length > 0).ToArray() : [];
        return new SpeechOptions(values("voices"), values("supported_formats"));
    }

    // Отправляем WAV или другой выбранный файл формы multipart/form-data.
    public async Task<string> Transcribe(string model, string audioFile, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url + "/audio/transcriptions");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(model), "model"); form.Add(new StringContent("ru"), "language");
        form.Add(new ByteArrayContent(await File.ReadAllBytesAsync(audioFile, cancellation)), "file", Path.GetFileName(audioFile));
        request.Content = form;
        using var response = await http.SendAsync(request, cancellation);
        string text = await response.Content.ReadAsStringAsync(cancellation);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Ошибка распознавания HTTP {(int)response.StatusCode}: {text.Replace(key, "[скрыто]")}");
        using var document = JsonDocument.Parse(text);
        return document.RootElement.GetProperty("text").GetString() ?? "";
    }

    // Получаем бинарный MP3, а JSON-ошибку провайдера превращаем в обычное сообщение.
    public async Task<byte[]> Speak(string model, string voice, string format, string text, CancellationToken cancellation)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url + "/audio/speech");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key);
        object body = string.IsNullOrWhiteSpace(voice)
            ? new { model, input = text, response_format = format }
            : new { model, voice, input = text, response_format = format };
        request.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        using var response = await http.SendAsync(request, cancellation);
        byte[] data = await response.Content.ReadAsByteArrayAsync(cancellation);
        if (!response.IsSuccessStatusCode)
        {
            string message = Encoding.UTF8.GetString(data).Replace(key, "[скрыто]");
            throw new InvalidOperationException($"Ошибка озвучки HTTP {(int)response.StatusCode}: {message}");
        }
        if (format != "mp3") throw new InvalidDataException($"Ответ {format} получен, но проигрыватель приложения сейчас ожидает MP3.");
        return data;
    }

    // Передаём историю и инструкции проекта, не включая скрытые локальные файлы.
    public async Task<ChatOutcome> Chat(string model, IEnumerable<Turn> turns, string prompt, string[] attachments, bool allowTools, Func<string, Task<string>> executeCommand, CancellationToken cancellation)
    {
        var messages = new List<object>();
        string rules = Path.Combine(AppContext.BaseDirectory, "AGENTS.md");
        if (File.Exists(rules)) messages.Add(new { role = "system", content = await File.ReadAllTextAsync(rules, cancellation) });
        foreach (var turn in turns.TakeLast(20))
        {
            messages.Add(new { role = "user", content = BuildContent(turn.User, turn.Attachments) });
            messages.Add(new { role = "assistant", content = turn.Assistant });
        }
        messages.Add(new { role = "user", content = BuildContent(prompt, attachments) });
        object[] tools = [new { type = "function", function = new { name = "run_powershell", description = "Выполнить одну команду PowerShell локально в Windows; команда должна быть показана и подтверждена пользователем.", parameters = new { type = "object", properties = new { command = new { type = "string", description = "Команда PowerShell целиком" } }, required = new[] { "command" }, additionalProperties = false } } }];
        var commandLog = new List<string>();
        for (int step = 0; step < 6; step++)
        {
            var payload = new Dictionary<string, object> { ["model"] = model, ["messages"] = messages, ["max_tokens"] = 4096 };
            if (allowTools) { payload["tools"] = tools; payload["tool_choice"] = "auto"; payload["parallel_tool_calls"] = false; }
            using var document = JsonDocument.Parse(await Request(HttpMethod.Post, "/chat/completions", payload, cancellation));
            JsonElement assistant = document.RootElement.GetProperty("choices")[0].GetProperty("message");
            if (allowTools && assistant.TryGetProperty("tool_calls", out var calls) && calls.ValueKind == JsonValueKind.Array && calls.GetArrayLength() > 0)
            {
                messages.Add(JsonSerializer.Deserialize<object>(assistant.GetRawText())!);
                foreach (var call in calls.EnumerateArray())
                {
                    string id = call.GetProperty("id").GetString() ?? throw new InvalidDataException("Вызову инструмента не присвоен ID.");
                    var function = call.GetProperty("function");
                    string name = function.GetProperty("name").GetString() ?? "";
                    string output;
                    if (name != "run_powershell") output = "Ошибка: неизвестный локальный инструмент.";
                    else
                    {
                        using var arguments = JsonDocument.Parse(function.GetProperty("arguments").GetString() ?? "{}");
                        string command = arguments.RootElement.GetProperty("command").GetString() ?? "";
                        output = await executeCommand(command);
                        commandLog.Add($"PowerShell:\n{command}\nРезультат:\n{output}");
                    }
                    messages.Add(new { role = "tool", tool_call_id = id, content = output });
                }
                continue;
            }
            if (!assistant.TryGetProperty("content", out var content)) throw new InvalidDataException("Ответ модели не содержит текста.");
            string text = content.ValueKind == JsonValueKind.String ? content.GetString() ?? "" : content.ValueKind == JsonValueKind.Array
                ? string.Join("\n", content.EnumerateArray().Where(part => part.TryGetProperty("text", out _)).Select(part => part.GetProperty("text").GetString())) : "";
            if (text.Length == 0) throw new InvalidDataException("Ответ модели не содержит текста.");
            return new ChatOutcome(text, commandLog.ToArray());
        }
        throw new InvalidOperationException("Модель запросила слишком много последовательных команд. Ограничение: 5 шагов.");
    }

    // Формируем части запроса для текста, изображений и PDF.
    private static object BuildContent(string text, string[] files)
    {
        if (files.Length == 0) return text;
        var parts = new List<object> { new { type = "text", text } };
        foreach (string relativePath in files)
        {
            string path = Path.IsPathRooted(relativePath) ? relativePath : Path.Combine(AppContext.BaseDirectory, relativePath);
            if (!File.Exists(path)) { parts.Add(new { type = "text", text = $"Вложение отсутствует: {Path.GetFileName(path)}" }); continue; }
            byte[] data = File.ReadAllBytes(path);
            string mime = Path.GetExtension(path).ToLowerInvariant() switch
            {
                ".jpg" or ".jpeg" => "image/jpeg", ".png" => "image/png", ".webp" => "image/webp", ".pdf" => "application/pdf",
                _ => "text/plain"
            };
            string dataUrl = $"data:{mime};base64,{Convert.ToBase64String(data)}";
            if (mime.StartsWith("image/")) parts.Add(new { type = "image_url", image_url = new { url = dataUrl } });
            else if (mime == "application/pdf") parts.Add(new { type = "file", file = new { filename = Path.GetFileName(path), file_data = dataUrl } });
            else parts.Add(new { type = "text", text = $"--- {Path.GetFileName(path)} ---\n{Encoding.UTF8.GetString(data)}" });
        }
        return parts;
    }
}
