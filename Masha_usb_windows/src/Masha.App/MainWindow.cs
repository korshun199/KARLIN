using System.Text;
using System.Text.Json;

namespace Masha.App;

// Окно хранит диалоги рядом с EXE и не блокируется во время запросов.
internal sealed class MainWindow : Form
{
    // Модель всегда может запросить локальную команду, но каждое выполнение подтверждается отдельно.
    internal const bool AgentToolsAlwaysAvailable = true;
    private readonly string root = AppContext.BaseDirectory;
    private readonly RichTextBox transcript = new() { Dock = DockStyle.Fill, ReadOnly = true };
    private readonly TextBox input = new() { Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Vertical, AcceptsReturn = true };
    private readonly ComboBox models = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox sessions = new() { Width = 250, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox transcriptionModels = new() { Width = 180, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox speechModels = new() { Width = 180, DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox voices = new() { Width = 90, DropDownStyle = ComboBoxStyle.DropDown };
    // Нижняя строка показывает текущий статус и имена выбранных файлов.
    private readonly Label status = new() { Dock = DockStyle.Fill, Text = "Готово", TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(4, 0, 8, 0) };
    // Список имён может не помещаться целиком; полная строка доступна во всплывающей подсказке.
    private readonly Label attachmentPreview = new() { Dock = DockStyle.Fill, Text = "Файлы не выбраны", TextAlign = ContentAlignment.MiddleLeft, Padding = new Padding(8, 0, 4, 0), AutoEllipsis = true, Tag = "muted" };
    // Кнопка настроек отображается шестерёнкой в правом верхнем углу.
    private readonly IconButton settingsButton = new(IconButtonKind.Settings, "Настройки");
    private readonly IconButton attachFile = new(IconButtonKind.Attachment, "Прикрепить файл");
    private readonly IconButton voiceInput = new(IconButtonKind.Microphone, "Голосовой ввод");
    // Кнопка отправки намеренно текстовая и шире остальных кнопок нижней панели.
    private readonly Button send = new() { Text = "ОТПРАВИТЬ", AutoSize = false, Tag = "primary", AccessibleName = "Отправить сообщение", AccessibleDescription = "Отправить сообщение", Font = new Font("Segoe UI", 9.5F, FontStyle.Bold), UseVisualStyleBackColor = false };
    private readonly IconButton cancel = new(IconButtonKind.Cancel, "Отменить запрос") { Enabled = false, Visible = false };
    private readonly ToolTip toolTips = new();
    private readonly List<Control> lockedControls = [];
    private readonly List<string> attachments = [];
    private readonly Settings settings;
    private readonly SessionStore store;
    private readonly AppTheme theme;
    private string key;
    private CancellationTokenSource? active;
    private bool changingSessions;
    private bool recording;
    private string recordingPath = "";

    // Загружаем настройки и состояние до создания элементов интерфейса.
    public MainWindow()
    {
        Text = "AI Model Masha 2026";
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(780, 550);
        ClientSize = new Size(1060, 720);
        Font = new Font("Segoe UI", 10F);
        theme = AppTheme.Load(root);
        models.Width = theme.FooterModelSelectorWidth;
        attachFile.Size = voiceInput.Size = cancel.Size = settingsButton.Size = new Size(theme.FooterIconButtonSize, theme.FooterIconButtonSize);
        send.Size = new Size(theme.FooterSendButtonWidth, theme.FooterIconButtonSize);
        models.Margin = send.Margin = cancel.Margin = new Padding(3);
        string config = Path.Combine(root, "config.json");
        settings = File.Exists(config) ? JsonSerializer.Deserialize<Settings>(File.ReadAllText(config)) ?? new Settings() : new Settings();
        string keyPath = Path.Combine(root, "api_key.txt");
        key = File.Exists(keyPath) ? File.ReadAllText(keyPath).Trim() : Environment.GetEnvironmentVariable("AITUNNEL_API_KEY") ?? "";
        store = new SessionStore();

        // Выделяем отдельные ячейки шапки для названия слева и автора с настройками справа.
        var top = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, RowCount = 1, Padding = new Padding(6) };
        top.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); top.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        // Выводим название программы крупнее обычных подписей.
        var appTitle = new Label { Text = "AI Model Masha 2026", AutoSize = true, Padding = new Padding(4, 8, 12, 0),
            Font = new Font(Font.FontFamily, 12F, FontStyle.Bold) };
        string[] chatModels = ChatModelCatalog.Read();
        models.Items.AddRange(chatModels);
        models.SelectedItem = chatModels.Contains(settings.Model, StringComparer.Ordinal)
            ? settings.Model
            : chatModels.Contains("gpt-6-luna", StringComparer.Ordinal) ? "gpt-6-luna" : chatModels.FirstOrDefault();
        // Выводим авторскую подпись приглушённым цветом, не отвлекая от переписки.
        var author = new Label { Text = "Author: Sinelnikov Oleg 2026", AutoSize = true, TextAlign = ContentAlignment.MiddleRight,
            Anchor = AnchorStyles.Top | AnchorStyles.Right, Padding = new Padding(12, 8, 4, 0), Font = new Font(Font.FontFamily, 9F), Tag = "muted" };
        // Прижимаем автора и следующую за подписью шестерёнку к правому краю.
        var authorActions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = false, FlowDirection = FlowDirection.RightToLeft };
        authorActions.Controls.AddRange([settingsButton, author]);
        top.Controls.Add(appTitle, 0, 0); top.Controls.Add(authorActions, 1, 0);
        var clearAttachmentsButton = MakeButton("Очистить", ClearAttachments);
        var second = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = true, Padding = new Padding(6) };
        second.Controls.AddRange([new Label { Text = "Диалог:", AutoSize = true, Padding = new Padding(0, 8, 0, 0) }, sessions,
            MakeButton("Новый", NewSession),
            MakeButton("Обновить модели", async () => await LoadModels()), MakeButton("Баланс", async () => await ShowBalance())]);
        transcriptionModels.Text = settings.TranscriptionModel; speechModels.Text = settings.SpeechModel; voices.Text = settings.Voice;
        var third = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = true, Padding = new Padding(6) };
        third.Controls.AddRange([MakeButton("Модели распознавания", async () => await LoadAudioModels("transcriptions", transcriptionModels)), transcriptionModels,
            MakeButton("Модели озвучки", async () => await LoadAudioModels("speech", speechModels)), speechModels, voices,
            MakeButton("Озвучить ответ", async () => await SpeakLast())]);
        lockedControls.Add(top); lockedControls.Add(second); lockedControls.Add(third); lockedControls.Add(models); lockedControls.Add(clearAttachmentsButton);
        var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Padding = new Padding(6) };
        footer.RowStyles.Add(new RowStyle(SizeType.Absolute, theme.FooterIconButtonSize + 8));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        // Размещаем статус и имена вложений в средней части единственной нижней строки.
        var footerInfo = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, RowCount = 1, Padding = new Padding(2, 0, 2, 0) };
        footerInfo.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize)); footerInfo.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100)); footerInfo.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        footerInfo.Controls.Add(status, 0, 0); footerInfo.Controls.Add(attachmentPreview, 1, 0); footerInfo.Controls.Add(clearAttachmentsButton, 2, 0);
        var inputActions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = false, Padding = new Padding(2) };
        inputActions.Controls.AddRange([attachFile, voiceInput]);
        var modelActions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, WrapContents = false, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(2) };
        modelActions.Controls.AddRange([send, cancel, models]);
        footer.Controls.Add(inputActions, 0, 0); footer.Controls.Add(footerInfo, 1, 0); footer.Controls.Add(modelActions, 2, 0);
        toolTips.SetToolTip(attachFile, "Прикрепить файл"); toolTips.SetToolTip(voiceInput, "Начать или остановить голосовой ввод");
        toolTips.SetToolTip(attachmentPreview, "Имена добавленных файлов появятся здесь");
        toolTips.SetToolTip(clearAttachmentsButton, "Очистить список вложений");
        toolTips.SetToolTip(send, "Отправить сообщение"); toolTips.SetToolTip(cancel, "Отменить текущий запрос");
        toolTips.SetToolTip(settingsButton, "Настройки");
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6 };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize)); layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 125)); layout.RowStyles.Add(new RowStyle(SizeType.Absolute, theme.FooterIconButtonSize + 20));
        layout.Controls.Add(top, 0, 0); layout.Controls.Add(second, 0, 1); layout.Controls.Add(third, 0, 2);
        layout.Controls.Add(transcript, 0, 3); layout.Controls.Add(input, 0, 4); layout.Controls.Add(footer, 0, 5);
        Controls.Add(layout);
        theme.Apply(this);
        send.Click += async (_, _) => await Send();
        settingsButton.Click += (_, _) => { try { Configure(); } catch (Exception ex) { MessageBox.Show(ex.Message, "Маша", MessageBoxButtons.OK, MessageBoxIcon.Error); } };
        attachFile.Click += (_, _) => Attach();
        voiceInput.Click += async (_, _) => await ToggleRecording();
        cancel.Click += (_, _) => active?.Cancel();
        input.KeyDown += async (_, e) => { if (e.Control && e.KeyCode == Keys.Enter) { e.SuppressKeyPress = true; await Send(); } };
        sessions.SelectedIndexChanged += (_, _) => SwitchSession();
        speechModels.SelectionChangeCommitted += async (_, _) => await RunRequest(async (client, token) => await RefreshVoices(client, speechModels.Text, token));
        RefreshSessions();
        RefreshAttachmentPreview();
        ShowHistory();
    }

    private Button MakeButton(string title, Action action)
    {
        var button = new Button { Text = title, AutoSize = true };
        button.Click += (_, _) => { try { action(); } catch (Exception ex) { MessageBox.Show(ex.Message, "Маша", MessageBoxButtons.OK, MessageBoxIcon.Error); } };
        return button;
    }

    // Запрашиваем настройки, отдельно предлагая хранить ключ на накопителе.
    private void Configure()
    {
        using var dialog = new Form { Text = "Настройки", StartPosition = FormStartPosition.CenterParent, Size = new Size(600, 300), FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
        var address = new TextBox { Text = settings.BaseUrl, Dock = DockStyle.Fill };
        var secret = new TextBox { Text = key, Dock = DockStyle.Fill, UseSystemPasswordChar = true };
        var remember = new CheckBox { Text = "Сохранить ключ на флешке в открытом виде", AutoSize = true, Checked = File.Exists(Path.Combine(root, "api_key.txt")) };
        var save = new Button { Text = "Сохранить", DialogResult = DialogResult.OK, AutoSize = true, Tag = "primary" };
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(15), ColumnCount = 1, RowCount = 6 };
        layout.Controls.Add(new Label { Text = "Адрес API", AutoSize = true }); layout.Controls.Add(address);
        layout.Controls.Add(new Label { Text = "API-ключ", AutoSize = true }); layout.Controls.Add(secret);
        layout.Controls.Add(remember); layout.Controls.Add(save); dialog.Controls.Add(layout); dialog.AcceptButton = save;
        theme.Apply(dialog);
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        _ = new ProviderClient(address.Text, secret.Text);
        string keyPath = Path.Combine(root, "api_key.txt");
        if (!remember.Checked && File.Exists(keyPath)) throw new InvalidOperationException("Ключ уже сохранён в api_key.txt. Для удаления сначала удалите этот файл самостоятельно.");
        settings.BaseUrl = address.Text.Trim(); key = secret.Text.Trim();
        SaveSettings();
        if (remember.Checked) File.WriteAllText(keyPath, key);
        status.Text = remember.Checked ? "Ключ сохранён на флешке" : "Ключ действует до закрытия";
    }

    private void SaveSettings()
    {
        settings.Model = models.Text.Trim();
        settings.TranscriptionModel = transcriptionModels.Text.Trim();
        settings.SpeechModel = speechModels.Text.Trim();
        settings.Voice = voices.Text.Trim();
        File.WriteAllText(Path.Combine(root, "config.json"), JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
    }

    // Вызываем поставщика и возвращаем управление окну при ошибке или отмене.
    private async Task RunRequest(Func<ProviderClient, CancellationToken, Task> action)
    {
        if (active is not null) return;
        try
        {
            var client = new ProviderClient(settings.BaseUrl, key);
            active = new CancellationTokenSource(); send.Enabled = false; cancel.Enabled = true; cancel.Visible = true;
            foreach (Control control in lockedControls) control.Enabled = false;
            Log.Write("Запрос к провайдеру начат");
            status.Text = "Ожидание ответа…";
            await action(client, active.Token);
            status.Text = "Готово";
            Log.Write("Запрос к провайдеру завершён");
        }
        catch (OperationCanceledException) { status.Text = "Отменено"; Log.Write("Запрос отменён"); }
        catch (Exception ex) { status.Text = "Ошибка"; Log.Write("Ошибка запроса: " + ex.GetType().Name); MessageBox.Show(key.Length > 0 ? ex.Message.Replace(key, "[скрыто]") : ex.Message, "Ошибка", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        finally { active?.Dispose(); active = null; send.Enabled = true; cancel.Enabled = false; cancel.Visible = false; foreach (Control control in lockedControls) control.Enabled = true; }
    }

    private async Task LoadModels() => await RunRequest(async (client, token) =>
    {
        string[] result = await client.Models(token); string selected = models.Text;
        models.Items.Clear(); models.Items.AddRange(result);
        string? preferred = result.Contains(selected, StringComparer.Ordinal) ? selected
            : result.Contains("gpt-6-luna", StringComparer.Ordinal) ? "gpt-6-luna" : result.FirstOrDefault();
        models.SelectedItem = preferred;
        MessageBox.Show($"Получено совместимых и доступных ключу чат-моделей: {result.Length}", "Маша");
    });

    private async Task ShowBalance() => await RunRequest(async (client, token) => MessageBox.Show(await client.Status(token), "AITunnel"));

    // Получаем публичный список распознавания или озвучки и сохраняем выбранную модель.
    private async Task LoadAudioModels(string kind, ComboBox target) => await RunRequest(async (client, token) =>
    {
        string[] result = await client.AudioModels(kind, token);
        target.Items.Clear(); target.Items.AddRange(result);
        if (result.Length > 0)
        {
            string selected = result.Contains(target.Text) ? target.Text : result[0];
            target.SelectedIndex = Array.IndexOf(result, selected);
        }
        if (kind == "speech" && target.Text.Length > 0) await RefreshVoices(client, target.Text, token);
        status.Text = $"Моделей: {result.Length}";
    });

    // Подставляем допустимые голоса выбранной модели из публичного каталога.
    private async Task RefreshVoices(ProviderClient client, string model, CancellationToken token)
    {
        SpeechOptions options = await client.SpeechModelOptions(model, token);
        voices.Items.Clear(); voices.Items.AddRange(options.Voices);
        if (options.Voices.Length == 0) voices.Text = "";
        else if (!options.Voices.Contains(voices.Text)) voices.Text = options.Voices[0];
        if (!options.Formats.Contains("mp3")) status.Text = "Эта модель выдаёт PCM; встроенный проигрыватель ждёт MP3";
    }

    // Начинаем или останавливаем микрофонную запись и переводим её в текст.
    private async Task ToggleRecording()
    {
        if (!recording)
        {
            string folder = Path.Combine(root, "recordings"); Directory.CreateDirectory(folder);
            recordingPath = Path.Combine(folder, DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".wav");
            AudioDevice.StartRecording(); recording = true; status.Text = "Запись идёт; нажмите ещё раз для распознавания"; return;
        }
        AudioDevice.StopRecording(recordingPath); recording = false;
        if (new FileInfo(recordingPath).Length > 25L * 1024 * 1024) { status.Text = "Запись превышает лимит 25 МиБ"; return; }
        string model = transcriptionModels.Text.Trim();
        if (model.Length == 0) { status.Text = "Сначала выберите модель распознавания"; return; }
        await RunRequest(async (client, token) =>
        {
            string text = await client.Transcribe(model, recordingPath, token);
            input.Text = string.IsNullOrWhiteSpace(input.Text) ? text : input.Text + Environment.NewLine + text;
            status.Text = "Речь распознана; проверьте текст и нажмите Отправить";
        });
    }

    // Озвучиваем последний ответ в выбранном голосе и сохраняем MP3 на флешке.
    private async Task SpeakLast()
    {
        if (store.Turns.Count == 0) { status.Text = "Нет ответа для озвучивания"; return; }
        string model = speechModels.Text.Trim(), voice = voices.Text.Trim();
        if (model.Length == 0) { status.Text = "Выберите модель синтеза"; return; }
        await RunRequest(async (client, token) =>
        {
            SpeechOptions options = await client.SpeechModelOptions(model, token);
            if (!options.Formats.Contains("mp3")) throw new InvalidOperationException("Выберите модель синтеза, которая поддерживает MP3.");
            if (options.Voices.Length > 0 && !options.Voices.Contains(voice)) throw new InvalidOperationException("Выберите голос из списка этой модели.");
            string folder = Path.Combine(root, "recordings"); Directory.CreateDirectory(folder);
            string path = Path.Combine(folder, DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".mp3");
            byte[] audio = await client.Speak(model, voice, "mp3", store.Turns[^1].Assistant, token);
            await File.WriteAllBytesAsync(path, audio, token); AudioDevice.Play(path);
        });
    }

    // Отправляем снимок ввода; успешный ответ сохраняем до очистки поля.
    private async Task Send()
    {
        if (active is not null) return;
        string message = input.Text.Trim();
        if (message.Length == 0) { status.Text = "Введите сообщение"; return; }
        string model = models.Text.Trim();
        if (model.Length == 0) { status.Text = "Выберите модель"; return; }
        string prompt = message;
        string[] sessionAttachments = [];
        try
        {
            var savedFiles = new List<string>();
            foreach (string file in attachments)
            {
                var info = new FileInfo(file);
                string ext = info.Extension.ToLowerInvariant();
                if (info.Length > 25L * 1024 * 1024) throw new InvalidDataException($"Файл {info.Name} больше лимита 25 МиБ.");
                if (ext is not (".txt" or ".md" or ".json" or ".csv" or ".py" or ".cs" or ".js" or ".html" or ".xml" or ".log" or ".pdf" or ".jpg" or ".jpeg" or ".png" or ".webp"))
                    throw new InvalidDataException($"Тип файла {info.Name} пока не поддерживается.");
                if (ext is ".txt" or ".md" or ".json" or ".csv" or ".py" or ".cs" or ".js" or ".html" or ".xml" or ".log")
                    if (info.Length > 1024 * 1024) throw new InvalidDataException($"Текстовый файл {info.Name} больше 1 МиБ.");
                string folder = Path.Combine(root, "attachments"); Directory.CreateDirectory(folder);
                string stored = Path.Combine(folder, Guid.NewGuid().ToString("N") + "_" + Path.GetFileName(file));
                File.Copy(file, stored); savedFiles.Add(stored);
            }
            sessionAttachments = savedFiles.Select(path => Path.GetRelativePath(root, path)).ToArray();
            SaveSettings();
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Вложения", MessageBoxButtons.OK, MessageBoxIcon.Error); return; }
        await RunRequest(async (client, token) =>
        {
            ChatOutcome outcome = await client.Chat(model, store.Turns, prompt, sessionAttachments, AgentToolsAlwaysAvailable, ConfirmAndRunCommand, token);
            string answer = outcome.Commands.Length == 0 ? outcome.Text : string.Join("\n\n", outcome.Commands) + "\n\nМаша:\n" + outcome.Text;
            if (string.IsNullOrWhiteSpace(answer)) throw new InvalidDataException("Модель вернула пустой ответ.");
            store.Add(prompt, answer, sessionAttachments);
            if (input.Text.Trim() == message) input.Clear();
            attachments.Clear(); RefreshAttachmentPreview(); ShowHistory(); RefreshSessions();
        });
    }

    // Обновляем список имён в нижней полосе и оставляем полный перечень в подсказке.
    private void RefreshAttachmentPreview()
    {
        if (attachments.Count == 0)
        {
            attachmentPreview.Text = "Файлы не выбраны";
            toolTips.SetToolTip(attachmentPreview, "Имена добавленных файлов появятся здесь");
            return;
        }

        // Подстраховываемся на случай, если среда вернёт пустое имя пути.
        string[] names = attachments.Select(file => Path.GetFileName(file) ?? file).ToArray();
        attachmentPreview.Text = $"Файлы ({names.Length}): {string.Join("  •  ", names)}";
        toolTips.SetToolTip(attachmentPreview, "Добавленные файлы:\n" + string.Join("\n", names));
    }

    private void Attach()
    {
        using var dialog = new OpenFileDialog { Multiselect = true, Filter = "Поддерживаемые файлы|*.txt;*.md;*.json;*.csv;*.py;*.cs;*.js;*.html;*.xml;*.log;*.pdf;*.jpg;*.jpeg;*.png;*.webp|Все файлы|*.*" };
        if (dialog.ShowDialog(this) == DialogResult.OK)
        {
            attachments.AddRange(dialog.FileNames.Where(file => !attachments.Contains(file, StringComparer.OrdinalIgnoreCase)));
            status.Text = "Файлы добавлены";
            RefreshAttachmentPreview();
        }
    }

    // Очищаем выбор и одновременно обновляем подпись в нижней строке.
    private void ClearAttachments() { attachments.Clear(); status.Text = "Вложения убраны"; RefreshAttachmentPreview(); }

    // Показываем команду полностью; запускаем её только после явного согласия.
    private async Task<string> ConfirmAndRunCommand(string command)
    {
        using var dialog = new Form { Text = "Подтвердить команду Windows", StartPosition = FormStartPosition.CenterParent, Size = new Size(760, 520), MinimumSize = new Size(600, 400) };
        var warning = new Label { Dock = DockStyle.Top, Height = 66, Text = "Модель предлагает запустить эту команду PowerShell на компьютере.\nОна получит права текущего пользователя Windows, без повышения до администратора.", Padding = new Padding(12), Tag = "danger" };
        var code = new TextBox { Dock = DockStyle.Fill, Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Both, WordWrap = false, Font = new Font("Consolas", 10F), Text = command };
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, FlowDirection = FlowDirection.RightToLeft };
        var deny = new Button { Text = "Отказать", DialogResult = DialogResult.No, AutoSize = true };
        var accept = new Button { Text = "Выполнить команду", DialogResult = DialogResult.Yes, AutoSize = true, Tag = "primary" };
        buttons.Controls.Add(deny); buttons.Controls.Add(accept); dialog.Controls.Add(code); dialog.Controls.Add(buttons); dialog.Controls.Add(warning);
        theme.Apply(dialog);
        dialog.AcceptButton = deny; dialog.CancelButton = deny;
        if (dialog.ShowDialog(this) != DialogResult.Yes) return "Отказано пользователем; команда не выполнялась.";
        CommandResult result = await PowerShellRunner.Run(command, active?.Token ?? CancellationToken.None);
        string output = $"Код завершения: {result.ExitCode}\n{result.Output}";
        if (key.Length > 0) output = output.Replace(key, "[скрыто]");
        Log.Write($"Команда PowerShell завершена, код {result.ExitCode}");
        return output;
    }
    private void NewSession() { if (active is not null) return; store.New(); RefreshSessions(); ShowHistory(); }
    private void SwitchSession()
    {
        if (changingSessions || active is not null || sessions.SelectedItem is not string id || id == store.Id) return;
        try { store.Open(id); ShowHistory(); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "Диалог", MessageBoxButtons.OK, MessageBoxIcon.Error); RefreshSessions(); }
    }
    private void RefreshSessions()
    {
        changingSessions = true;
        try { sessions.Items.Clear(); sessions.Items.AddRange(store.List().ToArray()); sessions.SelectedItem = store.Id; }
        finally { changingSessions = false; }
    }
    private void ShowHistory()
    {
        transcript.Clear();
        foreach (var turn in store.Turns)
        {
            transcript.SelectionColor = System.Drawing.ColorTranslator.FromHtml(theme.UserAccent); transcript.AppendText("Вы: ");
            transcript.SelectionColor = System.Drawing.ColorTranslator.FromHtml(theme.TextPrimary); transcript.AppendText(turn.User + "\n\n");
            transcript.SelectionColor = System.Drawing.ColorTranslator.FromHtml(theme.AssistantAccent); transcript.AppendText("Маша: ");
            transcript.SelectionColor = System.Drawing.ColorTranslator.FromHtml(theme.TextPrimary); transcript.AppendText(turn.Assistant + "\n\n");
        }
        transcript.ScrollToCaret();
    }
}
