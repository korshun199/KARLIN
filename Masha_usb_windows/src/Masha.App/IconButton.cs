namespace Masha.App;

internal enum IconButtonKind
{
    Attachment,
    Microphone,
    Settings,
    Cancel
}

// Квадратная кнопка рисует простой векторный значок в цвете общей темы.
internal sealed class IconButton : Button
{
    // Запоминаем вид значка и задаём понятное имя для экранных средств доступности.
    public IconButtonKind Kind { get; }

    public IconButton(IconButtonKind kind, string accessibleName)
    {
        Kind = kind;
        Text = "";
        AutoSize = false;
        AccessibleRole = AccessibleRole.PushButton;
        AccessibleName = accessibleName;
        AccessibleDescription = accessibleName;
        UseVisualStyleBackColor = false;
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 1;
        TabStop = true;
    }

    // Рисуем значок после стандартного фона кнопки, используя ForeColor темы.
    protected override void OnPaint(PaintEventArgs eventArgs)
    {
        base.OnPaint(eventArgs);
        Graphics graphics = eventArgs.Graphics;
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        float scale = Math.Min(ClientSize.Width, ClientSize.Height) / 44f;
        float centerX = ClientSize.Width / 2f;
        float centerY = ClientSize.Height / 2f;
        using var pen = new Pen(ForeColor, Math.Max(1.7f, 2.2f * scale))
        {
            StartCap = System.Drawing.Drawing2D.LineCap.Round,
            EndCap = System.Drawing.Drawing2D.LineCap.Round,
            LineJoin = System.Drawing.Drawing2D.LineJoin.Round
        };

        switch (Kind)
        {
            case IconButtonKind.Attachment:
                DrawAttachment(graphics, pen, centerX, centerY, scale);
                break;
            case IconButtonKind.Microphone:
                DrawMicrophone(graphics, pen, centerX, centerY, scale);
                break;
            case IconButtonKind.Settings:
                DrawSettings(graphics, pen, centerX, centerY, scale);
                break;
            case IconButtonKind.Cancel:
                DrawCancel(graphics, pen, centerX, centerY, scale);
                break;
        }
    }

    // Рисуем скрепку как открытую плавную линию.
    private static void DrawAttachment(Graphics graphics, Pen pen, float centerX, float centerY, float scale)
    {
        float x = centerX, y = centerY;
        using var path = new System.Drawing.Drawing2D.GraphicsPath();
        path.AddBezier(x + 3 * scale, y - 10 * scale, x - 5 * scale, y - 10 * scale, x - 6 * scale, y - 4 * scale, x - 6 * scale, y);
        path.AddLine(x - 6 * scale, y, x - 6 * scale, y + 6 * scale);
        path.AddBezier(x - 6 * scale, y + 6 * scale, x - 6 * scale, y + 13 * scale, x + 5 * scale, y + 13 * scale, x + 5 * scale, y + 6 * scale);
        path.AddLine(x + 5 * scale, y + 6 * scale, x + 5 * scale, y - 4 * scale);
        path.AddBezier(x + 5 * scale, y - 4 * scale, x + 5 * scale, y - 8 * scale, x - scale, y - 8 * scale, x - scale, y - 4 * scale);
        path.AddLine(x - scale, y - 4 * scale, x - scale, y + 5 * scale);
        graphics.DrawPath(pen, path);
    }

    // Рисуем микрофон, стойку и основание.
    private static void DrawMicrophone(Graphics graphics, Pen pen, float centerX, float centerY, float scale)
    {
        graphics.DrawEllipse(pen, centerX - 5 * scale, centerY - 11 * scale, 10 * scale, 17 * scale);
        graphics.DrawArc(pen, centerX - 10 * scale, centerY - 7 * scale, 20 * scale, 21 * scale, 0, 180);
        graphics.DrawLine(pen, centerX, centerY + 14 * scale, centerX, centerY + 19 * scale);
        graphics.DrawLine(pen, centerX - 6 * scale, centerY + 19 * scale, centerX + 6 * scale, centerY + 19 * scale);
    }

    // Рисуем шестерёнку и центральное отверстие значка настроек.
    private static void DrawSettings(Graphics graphics, Pen pen, float centerX, float centerY, float scale)
    {
        graphics.DrawEllipse(pen, centerX - 8 * scale, centerY - 8 * scale, 16 * scale, 16 * scale);
        graphics.DrawEllipse(pen, centerX - 3 * scale, centerY - 3 * scale, 6 * scale, 6 * scale);
        for (int tooth = 0; tooth < 8; tooth++)
        {
            double angle = tooth * Math.PI / 4;
            float innerX = centerX + (float)Math.Cos(angle) * 9 * scale;
            float innerY = centerY + (float)Math.Sin(angle) * 9 * scale;
            float outerX = centerX + (float)Math.Cos(angle) * 13 * scale;
            float outerY = centerY + (float)Math.Sin(angle) * 13 * scale;
            graphics.DrawLine(pen, innerX, innerY, outerX, outerY);
        }
    }

    // Рисуем крестик остановки запроса.
    private static void DrawCancel(Graphics graphics, Pen pen, float centerX, float centerY, float scale)
    {
        graphics.DrawLine(pen, centerX - 8 * scale, centerY - 8 * scale, centerX + 8 * scale, centerY + 8 * scale);
        graphics.DrawLine(pen, centerX + 8 * scale, centerY - 8 * scale, centerX - 8 * scale, centerY + 8 * scale);
    }
}
