using System.Drawing;
using System.Drawing.Imaging;
using System.Windows.Forms;

namespace Masha.Prototype;

internal static class Program
{
    // Запускаем первое окно; тестовый режим включается только явным параметром.
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 0 && (args.Length != 2 || args[0] != "--smoke-test"))
        {
            MessageBox.Show("Неизвестные параметры запуска.", "Маша", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        // Тестовая папка задаётся только для автоматической проверки стенда.
        string? testDirectory = args.Length == 2 ? args[1] : null;
        if (testDirectory is not null && !Directory.Exists(testDirectory))
        {
            return 2;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        using var window = new PrototypeWindow(testDirectory);
        Application.Run(window);
        return window.TestFailed ? 3 : 0;
    }
}

internal sealed class PrototypeWindow : Form
{
    // Элементы первого окна и путь для проверки запуска на Windows.
    private readonly Label statusLabel;
    private readonly Button checkButton;
    private readonly string? testDirectory;

    public bool TestFailed { get; private set; }

    // Создаём окно без обращения к сети, ключам и личной истории.
    public PrototypeWindow(string? testDirectory)
    {
        this.testDirectory = testDirectory;
        Text = "Маша — первый запуск";
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(760, 440);
        MinimumSize = new Size(560, 380);
        BackColor = Color.FromArgb(18, 24, 35);
        ForeColor = Color.White;
        Font = new Font("Segoe UI", 11F);

        // Основная вертикальная раскладка масштабируется вместе с окном.
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(32),
            ColumnCount = 1,
            RowCount = 5,
            BackColor = BackColor
        };
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var title = new Label
        {
            Text = "МАША  /  WINDOWS",
            AutoSize = true,
            ForeColor = Color.FromArgb(111, 224, 190),
            Font = new Font("Segoe UI", 20F, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 16)
        };
        var description = new Label
        {
            Text = "Первый прототип окна",
            AutoSize = true,
            Font = new Font("Segoe UI", 15F, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 10)
        };
        var explanation = new Label
        {
            Text = "Проверяем запуск и работу интерфейса на Windows.\n" +
                   "Подключение к ИИ, голос и работа с файлами ещё не добавлены.",
            AutoSize = true,
            ForeColor = Color.FromArgb(191, 200, 214),
            MaximumSize = new Size(650, 0),
            Margin = new Padding(0, 0, 0, 20)
        };
        statusLabel = new Label
        {
            Name = "statusLabel",
            Text = "Нажмите кнопку, чтобы проверить окно.",
            AutoSize = true,
            ForeColor = Color.FromArgb(220, 228, 236),
            Margin = new Padding(0, 0, 0, 12)
        };
        checkButton = new Button
        {
            Name = "checkButton",
            Text = "Проверить окно",
            AutoSize = true,
            Padding = new Padding(18, 8, 18, 8),
            FlatStyle = FlatStyle.Flat,
            BackColor = Color.FromArgb(34, 129, 105),
            ForeColor = Color.White,
            UseVisualStyleBackColor = false
        };
        checkButton.Click += OnCheckClicked;

        // Добавляем элементы в порядке чтения и управления с клавиатуры.
        layout.Controls.Add(title, 0, 0);
        layout.Controls.Add(description, 0, 1);
        layout.Controls.Add(explanation, 0, 2);
        layout.Controls.Add(statusLabel, 0, 3);
        layout.Controls.Add(checkButton, 0, 4);
        Controls.Add(layout);
        AcceptButton = checkButton;
        Shown += OnWindowShown;
    }

    // Проверяем, что нажатие действительно изменяет состояние окна.
    private void OnCheckClicked(object? sender, EventArgs e)
    {
        statusLabel.Text = "Окно работает. Можно продолжать разработку!";
        statusLabel.ForeColor = Color.FromArgb(111, 224, 190);
    }

    // В тестовом режиме нажимаем кнопку и сохраняем результат и изображение окна.
    private void OnWindowShown(object? sender, EventArgs e)
    {
        if (testDirectory is null) return;

        BeginInvoke((Action)(() =>
        {
            try
            {
                checkButton.PerformClick();
                if (statusLabel.Text != "Окно работает. Можно продолжать разработку!")
                    throw new InvalidOperationException("Кнопка не изменила состояние окна.");

                using var image = new Bitmap(Width, Height);
                DrawToBitmap(image, new Rectangle(0, 0, image.Width, image.Height));
                using (var imageFile = new FileStream(Path.Combine(testDirectory, "window.png"), FileMode.CreateNew))
                    image.Save(imageFile, ImageFormat.Png);
                using (var resultFile = new FileStream(Path.Combine(testDirectory, "result.txt"), FileMode.CreateNew))
                using (var writer = new StreamWriter(resultFile))
                    writer.WriteLine("PASS: window shown and button updated status");
            }
            catch (Exception ex)
            {
                TestFailed = true;
                try
                {
                    using var file = new FileStream(Path.Combine(testDirectory, "error.txt"), FileMode.CreateNew);
                    using var writer = new StreamWriter(file);
                    writer.WriteLine(ex.ToString());
                }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            finally
            {
                Close();
            }
        }));
    }
}
