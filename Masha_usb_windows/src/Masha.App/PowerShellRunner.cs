using System.Diagnostics;
using System.Text;
using System.Xml;

namespace Masha.App;

internal sealed record CommandResult(int ExitCode, string Output);

// Запускаем команду в обычном PowerShell текущего пользователя Windows.
internal static class PowerShellRunner
{
    // Ограничиваем время и объём выдачи команды, чтобы окно оставалось отзывчивым.
    public static async Task<CommandResult> Run(string command, CancellationToken cancellation)
    {
        if (string.IsNullOrWhiteSpace(command)) throw new ArgumentException("Пустая команда PowerShell.");
        string prefix = "[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false); [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); $OutputEncoding = [System.Text.UTF8Encoding]::new($false); $ProgressPreference = 'SilentlyContinue'; ";
        string encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(prefix + command));
        var start = new ProcessStartInfo("powershell.exe")
        {
            Arguments = $"-NoLogo -NoProfile -NonInteractive -EncodedCommand {encoded}",
            WorkingDirectory = AppContext.BaseDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        using var process = new Process { StartInfo = start };
        if (!process.Start()) throw new InvalidOperationException("Не удалось запустить PowerShell.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMinutes(2));
        try
        {
            Task<string> stdout = process.StandardOutput.ReadToEndAsync(timeout.Token);
            Task<string> stderr = process.StandardError.ReadToEndAsync(timeout.Token);
            await process.WaitForExitAsync(timeout.Token);
            string output = (await stdout) + DecodeErrorOutput(await stderr);
            if (output.Length > 30000) output = output[..30000] + "\n[вывод обрезан: лимит 30000 символов]";
            return new CommandResult(process.ExitCode, string.IsNullOrWhiteSpace(output) ? "(команда не вывела текст)" : output);
        }
        catch
        {
            try { process.Kill(true); } catch (InvalidOperationException) { }
            throw;
        }
    }

    // Преобразуем служебный XML ошибок Windows PowerShell 5.1 в читаемый текст.
    private static string DecodeErrorOutput(string text)
    {
        if (!text.TrimStart().StartsWith("#< CLIXML", StringComparison.Ordinal)) return text;
        try
        {
            int start = text.IndexOf("<Objs", StringComparison.Ordinal);
            if (start < 0) return text;
            var document = new XmlDocument { XmlResolver = null };
            document.LoadXml(text[start..]);
            var nodes = document.SelectNodes("//*[local-name()='S' and @S='Error']");
            if (nodes is null || nodes.Count == 0) return text;
            return string.Concat(nodes.Cast<XmlNode>().Select(node => XmlConvert.DecodeName(node.InnerText)));
        }
        catch (XmlException) { return text; }
    }
}
