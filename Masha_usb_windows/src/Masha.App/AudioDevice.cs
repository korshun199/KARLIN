using System.Runtime.InteropServices;
using System.Text;

namespace Masha.App;

// Используем штатный Windows Multimedia API для WAV-записи и MP3-воспроизведения.
internal static class AudioDevice
{
    [DllImport("winmm.dll", CharSet = CharSet.Unicode)]
    private static extern int mciSendString(string command, StringBuilder? result, int length, IntPtr callback);

    // Превращаем код Windows в читаемую ошибку аудиоустройства.
    private static void Run(string command)
    {
        int error = mciSendString(command, null, 0, IntPtr.Zero);
        if (error == 0) return;
        var message = new StringBuilder(256);
        mciSendString($"error {error}", message, message.Capacity, IntPtr.Zero);
        throw new InvalidOperationException($"Аудиоустройство: {message}");
    }

    // Начинаем запись WAV: моно, 16 бит, 16 кГц.
    public static void StartRecording()
    {
        Run("open new type waveaudio alias masha_record");
        try { Run("set masha_record time format ms bitspersample 16 channels 1 samplespersec 16000"); Run("record masha_record"); }
        catch { mciSendString("close masha_record", null, 0, IntPtr.Zero); throw; }
    }

    // Останавливаем запись и сохраняем готовый WAV для отправки.
    public static void StopRecording(string path)
    {
        try { Run("stop masha_record"); Run($"save masha_record \"{path.Replace("\"", "")}\""); }
        finally { mciSendString("close masha_record", null, 0, IntPtr.Zero); }
    }

    // Воспроизводим MP3 средствами Windows.
    public static void Play(string path)
    {
        mciSendString("close masha_play", null, 0, IntPtr.Zero);
        Run($"open \"{path.Replace("\"", "")}\" type mpegvideo alias masha_play");
        Run("play masha_play");
    }
}
