using System.Net;
using System.Text;
using System.Text.Json;

namespace Masha.App;

// Проверка работает только в указанной пустой папке и использует искусственные данные.
internal static class SelfTest
{
    // Проверяем настоящий API минимальным сообщением без чтения пользовательских диалогов.
    public static int RunApi(string directory)
    {
        try
        {
            if (!Directory.Exists(directory) || Directory.EnumerateFileSystemEntries(directory).Any()) return 2;
            string key = Environment.GetEnvironmentVariable("AITUNNEL_API_KEY") ?? "";
            var client = new ProviderClient("https://api.aitunnel.ru/v1", key);
            var models = client.Models(CancellationToken.None).GetAwaiter().GetResult();
            var transcriptionModels = client.AudioModels("transcriptions", CancellationToken.None).GetAwaiter().GetResult();
            var speechModels = client.AudioModels("speech", CancellationToken.None).GetAwaiter().GetResult();
            var speechOptions = client.SpeechModelOptions("gpt-4o-mini-tts", CancellationToken.None).GetAwaiter().GetResult();
            string balance = client.Balance(CancellationToken.None).GetAwaiter().GetResult();
            string answer = client.Chat("gpt-6-luna", [], "Reply with the word OK.", [], false, _ => Task.FromResult("unused"), CancellationToken.None).GetAwaiter().GetResult().Text;
            if (string.IsNullOrWhiteSpace(answer)) throw new Exception("Empty model response");
            File.WriteAllText(Path.Combine(directory, "result.txt"), $"PASS: models={models.Length}; transcription models={transcriptionModels.Length}; speech models={speechModels.Length}; voices={speechOptions.Voices.Length}; balance received; chat response received");
            return 0;
        }
        catch (Exception ex)
        {
            string key = Environment.GetEnvironmentVariable("AITUNNEL_API_KEY") ?? "";
            string text = key.Length > 0 ? ex.Message.Replace(key, "[hidden]") : ex.Message;
            try { File.WriteAllText(Path.Combine(directory, "error.txt"), text); } catch (IOException) { }
            return 1;
        }
    }
    public static int Run(string directory)
    {
        try
        {
            if (!Directory.Exists(directory) || Directory.EnumerateFileSystemEntries(directory).Any()) return 2;
            var store = new SessionStore(directory);
            string id = store.Id;
            string attachment = Path.Combine(directory, "sample.txt");
            File.WriteAllText(attachment, "attachment check");
            string image = Path.Combine(directory, "sample.png"); File.WriteAllBytes(image, [137, 80, 78, 71]);
            string pdf = Path.Combine(directory, "sample.pdf"); File.WriteAllBytes(pdf, Encoding.ASCII.GetBytes("%PDF-test"));
            store.Add("Привет", "Здравствуйте", [attachment, image, pdf]);
            var restored = new SessionStore(directory);
            if (restored.Id != id || restored.Turns.Count != 1 || restored.Turns[0].Assistant != "Здравствуйте" || restored.Turns[0].Attachments.Length != 3) throw new Exception("Диалог или вложение не восстановлено.");
            var client = new ProviderClient("https://example.invalid/v1", "test-key", new FakeHandler());
            string[] filteredModels = client.Models(CancellationToken.None).GetAwaiter().GetResult();
            if (!filteredModels.Contains("gpt-6-luna") || filteredModels.Contains("model-test")) throw new Exception("Каталог чат-моделей не отфильтрован по совместимому списку.");
            if (client.Balance(CancellationToken.None).GetAwaiter().GetResult() != "12.5") throw new Exception("Не получен баланс.");
            var response = client.Chat("model-test", restored.Turns, "Второй вопрос", [], false, _ => Task.FromResult("unused"), CancellationToken.None).GetAwaiter().GetResult();
            if (response.Text != "Второй ответ") throw new Exception("Не получен ответ модели.");
            restored.Add("Второй вопрос", response.Text, []);
            if (new SessionStore(directory).Turns.Count != 2) throw new Exception("Ответ не сохранён.");
            CommandResult command = PowerShellRunner.Run("Write-Output agent-test", CancellationToken.None).GetAwaiter().GetResult();
            if (command.ExitCode != 0 || !command.Output.Contains("agent-test")) throw new Exception("PowerShell runner check failed.");
            int approvals = 0;
            if (!MainWindow.AgentToolsAlwaysAvailable) throw new Exception("Agent tools must always be available to the model.");
            var toolClient = new ProviderClient("https://example.invalid/v1", "test-key", new FakeToolHandler());
            var agent = toolClient.Chat("model-test", [], "Run safe check", [], MainWindow.AgentToolsAlwaysAvailable,
                _ => { approvals++; return Task.FromResult("Exit 0: tool-test"); }, CancellationToken.None).GetAwaiter().GetResult();
            if (approvals != 1 || agent.Text != "Agent tool test passed." || agent.Commands.Length != 1) throw new Exception("Agent tool loop check failed.");
            File.WriteAllText(Path.Combine(directory, "result.txt"), "PASS: sessions, restart, text/image/PDF attachments, API methods, PowerShell runner and confirmed-tool loop");
            return 0;
        }
        catch (Exception ex)
        {
            try { File.WriteAllText(Path.Combine(directory, "error.txt"), ex.ToString()); } catch (IOException) { }
            return 1;
        }
    }

    // Условный сервер проверяет ключ, историю и содержимое запроса без настоящего API.
    private sealed class FakeHandler : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.Headers.Authorization?.Parameter != "test-key") throw new Exception("Неверная авторизация.");
            string json;
            if (request.RequestUri?.AbsolutePath == "/v1/models") json = "{\"data\":[{\"id\":\"model-test\"},{\"id\":\"gpt-6-luna\"}]}";
            else if (request.RequestUri?.AbsolutePath == "/v1/aitunnel/balance") json = "{\"balance\":12.5}";
            else if (request.RequestUri?.AbsolutePath == "/v1/chat/completions")
            {
                using var doc = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
                var messages = doc.RootElement.GetProperty("messages");
                if (doc.RootElement.GetProperty("model").GetString() != "model-test" || messages.GetArrayLength() < 3 || messages[messages.GetArrayLength() - 1].GetProperty("content").GetString() != "Второй вопрос") throw new Exception("Invalid chat message sequence");
                var previous = messages.EnumerateArray().First(message => message.GetProperty("role").GetString() == "user").GetProperty("content");
                if (previous.ValueKind != JsonValueKind.Array || previous.GetArrayLength() != 4 || !previous[1].GetProperty("text").GetString()!.Contains("attachment check") || previous[2].GetProperty("image_url").GetProperty("url").GetString()!.StartsWith("data:image/png;base64,") == false || !previous[3].GetProperty("file").GetProperty("file_data").GetString()!.StartsWith("data:application/pdf;base64,")) throw new Exception("Attachment request format is incorrect");
                json = "{\"choices\":[{\"message\":{\"content\":\"Второй ответ\"}}]}";
            }
            else return new HttpResponseMessage(HttpStatusCode.NotFound);
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(json, Encoding.UTF8, "application/json") };
        }
    }

    // Модель сначала предлагает одну команду; тестовый обработчик подтверждает и возвращает финальный ответ.
    private sealed class FakeToolHandler : HttpMessageHandler
    {
        private int step;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.Headers.Authorization?.Parameter != "test-key") throw new Exception("Invalid test authorization");
            using var document = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellationToken));
            if (!document.RootElement.TryGetProperty("tools", out _)) throw new Exception("Agent tools missing in provider request");
            if (step++ == 0)
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"id\":\"call-test\",\"type\":\"function\",\"function\":{\"name\":\"run_powershell\",\"arguments\":\"{\\\"command\\\":\\\"Write-Output agent-test\\\"}\"}}]}}]}", Encoding.UTF8, "application/json") };
            var messages = document.RootElement.GetProperty("messages");
            if (!messages.EnumerateArray().Any(message => message.TryGetProperty("role", out var role) && role.GetString() == "tool" && message.GetProperty("tool_call_id").GetString() == "call-test")) throw new Exception("Tool result missing from follow-up");
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"choices\":[{\"message\":{\"content\":\"Agent tool test passed.\"}}]}", Encoding.UTF8, "application/json") };
        }
    }
}
