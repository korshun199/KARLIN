using System.Globalization;
using System.Text.Json;

namespace Masha.App;

// Единая контрастная палитра применяется ко всем окнам и их элементам.
internal sealed class AppTheme
{
    // Фон главного и модальных окон.
    public string WindowBackground { get; set; } = "#111827";
    // Фон панелей, подписей и обычных контейнеров.
    public string SurfaceBackground { get; set; } = "#1F2937";
    // Фон полей ввода и истории диалога.
    public string InputBackground { get; set; } = "#0B1220";
    // Основной цвет текста.
    public string TextPrimary { get; set; } = "#F8FAFC";
    // Приглушённый текст для второстепенных подписей.
    public string TextMuted { get; set; } = "#CBD5E1";
    // Фон обычных кнопок.
    public string ButtonBackground { get; set; } = "#334155";
    // Текст обычных кнопок.
    public string ButtonText { get; set; } = "#F8FAFC";
    // Фон обычной кнопки при наведении.
    public string ButtonHover { get; set; } = "#475569";
    // Основной бирюзовый акцент интерфейса.
    public string Accent { get; set; } = "#22D3EE";
    // Тёмный текст на бирюзовой акцентной кнопке.
    public string AccentText { get; set; } = "#082F49";
    // Фон акцентной кнопки при наведении.
    public string AccentHover { get; set; } = "#67E8F9";
    // Цвет границ элементов.
    public string Border { get; set; } = "#64748B";
    // Цвет выделения в списках и активных состояниях.
    public string SelectionBackground { get; set; } = "#0E7490";
    // Текст на фоне выделения.
    public string SelectionText { get; set; } = "#FFFFFF";
    // Цвет подписи пользователя в истории.
    public string UserAccent { get; set; } = "#7DD3FC";
    // Цвет подписи Маши в истории.
    public string AssistantAccent { get; set; } = "#6EE7B7";
    // Цвет предупреждений и ошибок.
    public string Danger { get; set; } = "#FDA4AF";
    // Размер квадратных кнопок со значками в нижней панели.
    public int FooterIconButtonSize { get; set; } = 44;
    // Ширина выпадающего списка модели в нижней панели.
    public int FooterModelSelectorWidth { get; set; } = 220;
    // Ширина текстовой кнопки отправки в нижней панели.
    public int FooterSendButtonWidth { get; set; } = 148;

    // Загружаем theme.json; при ошибке безопасно возвращаем встроенную палитру.
    public static AppTheme Load(string directory)
    {
        string path = Path.Combine(directory, "theme.json");
        if (!File.Exists(path))
        {
            Log.Write("theme.json не найден; используется контрастная палитра по умолчанию");
            return new AppTheme();
        }

        try
        {
            AppTheme theme = JsonSerializer.Deserialize<AppTheme>(File.ReadAllText(path))
                ?? throw new InvalidDataException("Файл темы пуст.");
            theme.Validate();
            return theme;
        }
        catch (Exception error) when (error is IOException or JsonException or InvalidDataException or FormatException)
        {
            Log.Write($"theme.json некорректен; используется палитра по умолчанию ({error.GetType().Name})");
            return new AppTheme();
        }
    }

    // Применяем цвета ко всем вложенным элементам указанного окна.
    public void Apply(Form form)
    {
        ApplyControl(form);
    }

    // Задаём каждой категории контрола явную пару фона и текста.
    private void ApplyControl(Control control)
    {
        if (control is Form)
        {
            control.BackColor = ParseColor(WindowBackground);
            control.ForeColor = ParseColor(TextPrimary);
        }
        else if (control is RichTextBox transcript)
        {
            transcript.BackColor = ParseColor(InputBackground);
            transcript.ForeColor = ParseColor(TextPrimary);
            transcript.BorderStyle = BorderStyle.FixedSingle;
        }
        else if (control is TextBoxBase input)
        {
            input.BackColor = ParseColor(InputBackground);
            input.ForeColor = ParseColor(TextPrimary);
            input.BorderStyle = BorderStyle.FixedSingle;
        }
        else if (control is ComboBox combo)
        {
            combo.BackColor = ParseColor(InputBackground);
            combo.ForeColor = ParseColor(TextPrimary);
            combo.FlatStyle = FlatStyle.Flat;
        }
        else if (control is Button button)
        {
            ApplyButton(button);
        }
        else if (control is CheckBox checkBox)
        {
            checkBox.BackColor = ParseColor(SurfaceBackground);
            checkBox.ForeColor = ParseColor(TextPrimary);
            checkBox.FlatStyle = FlatStyle.Flat;
            checkBox.UseVisualStyleBackColor = false;
        }
        else if (control is Label label)
        {
            label.BackColor = ParseColor(SurfaceBackground);
            label.ForeColor = label.Tag?.ToString() switch
            {
                "muted" => ParseColor(TextMuted),
                "danger" => ParseColor(Danger),
                "user" => ParseColor(UserAccent),
                "assistant" => ParseColor(AssistantAccent),
                _ => ParseColor(TextPrimary)
            };
        }
        else
        {
            control.BackColor = ParseColor(SurfaceBackground);
            control.ForeColor = ParseColor(TextPrimary);
        }

        foreach (Control child in control.Controls) ApplyControl(child);
    }

    // Различаем акцентную кнопку отправки и обычные кнопки управления.
    private void ApplyButton(Button button)
    {
        bool primary = button.Tag?.ToString() == "primary";
        button.UseVisualStyleBackColor = false;
        button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 1;
        button.FlatAppearance.BorderColor = ParseColor(Border);
        button.FlatAppearance.MouseOverBackColor = ParseColor(primary ? AccentHover : ButtonHover);
        button.FlatAppearance.MouseDownBackColor = ParseColor(primary ? AccentHover : ButtonHover);
        button.BackColor = ParseColor(primary ? Accent : ButtonBackground);
        button.ForeColor = ParseColor(primary ? AccentText : ButtonText);
    }

    // Проверяем HEX-цвет и возвращаем его как объект Color.
    private static System.Drawing.Color ParseColor(string? value)
    {
        if (value is null || value.Length != 7 || value[0] != '#'
            || !byte.TryParse(value.AsSpan(1, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out byte red)
            || !byte.TryParse(value.AsSpan(3, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out byte green)
            || !byte.TryParse(value.AsSpan(5, 2), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out byte blue))
            throw new InvalidDataException("Цвет должен быть указан в формате #RRGGBB.");
        return System.Drawing.Color.FromArgb(red, green, blue);
    }

    // Проверяем корректность цветов и минимальный контраст WCAG 4.5:1.
    private void Validate()
    {
        if (FooterIconButtonSize is < 36 or > 80 || FooterModelSelectorWidth is < 140 or > 520
            || FooterSendButtonWidth is < 120 or > 260)
            throw new InvalidDataException("Размеры элементов нижней панели вне допустимых границ.");

        var window = ParseColor(WindowBackground);
        var surface = ParseColor(SurfaceBackground);
        var input = ParseColor(InputBackground);
        var button = ParseColor(ButtonBackground);
        var buttonHover = ParseColor(ButtonHover);
        var accent = ParseColor(Accent);
        var accentHover = ParseColor(AccentHover);
        var selection = ParseColor(SelectionBackground);
        RequireContrast(ParseColor(TextPrimary), window, "основной текст / окно");
        RequireContrast(ParseColor(TextPrimary), surface, "основной текст / панель");
        RequireContrast(ParseColor(TextPrimary), input, "основной текст / поле");
        RequireContrast(ParseColor(TextMuted), surface, "приглушённый текст / панель");
        RequireContrast(ParseColor(ButtonText), button, "текст кнопки / кнопка");
        RequireContrast(ParseColor(ButtonText), buttonHover, "текст кнопки / наведение");
        RequireContrast(ParseColor(AccentText), accent, "текст акцента / акцент");
        RequireContrast(ParseColor(AccentText), accentHover, "текст акцента / наведение");
        RequireContrast(ParseColor(SelectionText), selection, "текст выделения / выделение");
        RequireContrast(ParseColor(UserAccent), input, "подпись пользователя / история");
        RequireContrast(ParseColor(AssistantAccent), input, "подпись Маши / история");
        RequireContrast(ParseColor(Danger), surface, "ошибка / панель");
    }

    // Отклоняем цветовые сочетания, в которых надпись будет плохо различима.
    private static void RequireContrast(System.Drawing.Color foreground, System.Drawing.Color background, string description)
    {
        if (ContrastRatio(foreground, background) < 4.5)
            throw new InvalidDataException($"Недостаточный контраст для сочетания «{description}»; требуется не менее 4.5:1.");
    }

    // Вычисляем контраст по относительной яркости WCAG.
    private static double ContrastRatio(System.Drawing.Color first, System.Drawing.Color second)
    {
        double firstLuminance = Luminance(first), secondLuminance = Luminance(second);
        double lighter = Math.Max(firstLuminance, secondLuminance);
        double darker = Math.Min(firstLuminance, secondLuminance);
        return (lighter + 0.05) / (darker + 0.05);
    }

    // Переводим sRGB-компоненты в относительную яркость.
    private static double Luminance(System.Drawing.Color color)
    {
        static double Linear(byte component)
        {
            double value = component / 255.0;
            return value <= 0.04045 ? value / 12.92 : Math.Pow((value + 0.055) / 1.055, 2.4);
        }

        return 0.2126 * Linear(color.R) + 0.7152 * Linear(color.G) + 0.0722 * Linear(color.B);
    }
}
