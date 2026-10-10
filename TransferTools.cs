using System;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace ChatGPTRuntimeLauncher
{
    public sealed class TransferResult
    {
        public int ExitCode { get; set; }
        public string Output { get; set; }
        public string Method { get; set; }
        public string FailureOrigin { get; set; }
        public int NativeCode { get; set; }
        public bool CompatibilityFailure { get; set; }
        public Entry[] Entries { get; set; }
        public int CompletedFiles { get; set; }
        public int TotalFiles { get; set; }
        public int MaxActiveWorkers { get; set; }
        public int BufferBytes { get; set; }
    }

    // 每个任务独占一个 1 MiB 缓冲。失败后停止取新文件，并等待全部流关闭。
    public sealed class TransferJob
    {
        public const int WorkerLimit = 4;
        public const int BufferSize = 1024 * 1024;
        private readonly object gate = new object();
        private Task task;
        private int stop, completed, active, maxActive;
        private TransferResult result;
        public int CompletedFiles { get { return Volatile.Read(ref completed); } }
        public int TotalFiles { get; private set; }
        public bool Wait(int milliseconds) { return task.Wait(milliseconds); }
        public TransferResult Finish() { task.Wait(); return result; }

        public static TransferJob Copy(string source, string destination, string entriesJson)
        {
            var job = new TransferJob();
            job.Start(source, destination, entriesJson, true);
            return job;
        }

        public static TransferJob HashTree(string root)
        {
            var job = new TransferJob();
            job.Start(root, null, null, false);
            return job;
        }

        private void Start(string source, string destination, string entriesJson, bool copy)
        {
            task = Task.Factory.StartNew(() => {
                result = new TransferResult { Method = copy ? "stream" : "sha256", BufferBytes = BufferSize };
                try
                {
                    Files.ReadSafe(source);
                    Entry[] entries = copy ? Files.Serializer().Deserialize<Entry[]>(entriesJson) : Files.Inventory(source, false);
                    if (entries == null || entries.Length == 0) throw new IOException("源运行时清单为空。");
                    Entry[] files = entries.Where(e => !e.Directory).ToArray();
                    TotalFiles = files.Length;
                    if (copy)
                    {
                        Files.NoReparse(destination);
                        System.IO.Directory.CreateDirectory(destination);
                        foreach (Entry entry in entries)
                        {
                            // 先验证所有清单路径，随后才创建目录或打开文件。
                            Files.ReadWithin(source, System.IO.Path.Combine(source, entry.Path));
                            Files.Within(destination, System.IO.Path.Combine(destination, entry.Path), false);
                        }
                        foreach (Entry entry in entries.Where(e => e.Directory).OrderBy(e => e.Path.Length))
                            System.IO.Directory.CreateDirectory(Files.Within(destination, System.IO.Path.Combine(destination, entry.Path), false));
                    }
                    int next = -1;
                    var workers = new List<Task>();
                    for (int w = 0; w < Math.Min(WorkerLimit, files.Length); w++)
                    {
                        workers.Add(Task.Factory.StartNew(() => {
                            byte[] buffer = new byte[BufferSize];
                            while (Volatile.Read(ref stop) == 0)
                            {
                                int index = Interlocked.Increment(ref next);
                                if (index >= files.Length) break;
                                int count = Interlocked.Increment(ref active);
                                int seen;
                                do { seen = Volatile.Read(ref maxActive); }
                                while (count > seen && Interlocked.CompareExchange(ref maxActive, count, seen) != seen);
                                try { TransferFile(source, destination, files[index], buffer, copy); }
                                catch (TransferFailure failure) { Fail(failure.Origin, failure.Cause, failure.Compatible); }
                                catch (Exception error) { Fail("Boundary", error, false); }
                                finally { Interlocked.Decrement(ref active); }
                            }
                        }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default));
                    }
                    Task.WaitAll(workers.ToArray());
                    if (result.ExitCode == 0 && copy)
                    {
                        if (Files.Fingerprint(Files.Inventory(source, false)) != Files.Fingerprint(entries))
                            Fail("SourceChanged", new IOException("复制期间源目录清单发生变化。"), false);
                    }
                    result.Entries = entries.OrderBy(e => e.Path, StringComparer.Ordinal).ToArray();
                }
                catch (Exception error) { Fail("Boundary", error, false); }
                result.CompletedFiles = CompletedFiles;
                result.TotalFiles = TotalFiles;
                result.MaxActiveWorkers = maxActive;
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        private void TransferFile(string source, string destination, Entry entry, byte[] buffer, bool copy)
        {
            string src = Files.ReadWithin(source, System.IO.Path.Combine(source, entry.Path));
            CheckSnapshot(src, entry);
            FileStream input;
            try { input = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan); }
            catch (Exception error) { throw new TransferFailure("SourceRead", error, copy && IsReadCompatibilityError(error)); }
            using (input)
            using (var sha = SHA256.Create())
            {
                FileStream output = null;
                try
                {
                    if (copy)
                    {
                        string dst = Files.Within(destination, System.IO.Path.Combine(destination, entry.Path), false);
                        try { output = new FileStream(dst, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.SequentialScan); }
                        catch (Exception error) { throw new TransferFailure("DestinationWrite", error, false); }
                    }
                    long length = 0;
                    while (true)
                    {
                        if (Volatile.Read(ref stop) != 0) return;
                        int read;
                        try { read = input.Read(buffer, 0, buffer.Length); }
                        catch (Exception error) { throw new TransferFailure("SourceRead", error, copy && IsReadCompatibilityError(error)); }
                        if (read == 0) break;
                        sha.TransformBlock(buffer, 0, read, buffer, 0);
                        if (copy)
                        {
                            try { output.Write(buffer, 0, read); }
                            catch (Exception error) { throw new TransferFailure("DestinationWrite", error, false); }
                        }
                        length += read;
                    }
                    sha.TransformFinalBlock(buffer, 0, 0);
                    if (length != entry.Length) throw new TransferFailure("SourceChanged", new IOException("读取期间文件大小发生变化。"), false);
                    CheckSnapshot(src, entry);
                    entry.Hash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    if (output != null)
                    {
                        try { output.Dispose(); output = null; }
                        catch (Exception error) { throw new TransferFailure("DestinationWrite", error, false); }
                        string dst = Files.Within(destination, System.IO.Path.Combine(destination, entry.Path), false);
                        if ((File.GetAttributes(dst) & FileAttributes.Encrypted) != 0)
                            throw new TransferFailure("DestinationWrite", new IOException("目标目录使文件继承了加密属性，已停止发布。"), false);
                    }
                    Interlocked.Increment(ref completed);
                }
                finally { if (output != null) output.Dispose(); }
            }
        }

        private static void CheckSnapshot(string path, Entry entry)
        {
            if (new FileInfo(path).Length != entry.Length || File.GetLastWriteTimeUtc(path).Ticks != entry.Modified)
                throw new TransferFailure("SourceChanged", new IOException("读取期间源文件发生变化：" + entry.Path), false);
        }

        public static bool IsReadCompatibilityError(Exception error)
        {
            int code = error.HResult & 0xffff;
            return error is UnauthorizedAccessException ||
                (error is IOException && (code == 5 || code == 6000 || code == 6001 || code == 6002 || code == 6005));
        }

        private void Fail(string origin, Exception error, bool compatible)
        {
            lock (gate)
            {
                // 同时发生目标写入等错误时，禁止将它误报为可回退的源读取错误。
                if (result.ExitCode == 0 || (result.CompatibilityFailure && !compatible))
                {
                    result.ExitCode = 1;
                    result.Output = error.Message;
                    result.FailureOrigin = origin;
                    result.NativeCode = error.HResult & 0xffff;
                    result.CompatibilityFailure = compatible;
                }
                Interlocked.Exchange(ref stop, 1);
            }
        }

        private sealed class TransferFailure : Exception
        {
            public string Origin;
            public Exception Cause;
            public bool Compatible;
            public TransferFailure(string origin, Exception cause, bool compatible)
            { Origin = origin; Cause = cause; Compatible = compatible; }
        }
    }

    public static class LegacyCopy
    {
        public static TransferResult Run(string source, string destination, ProgressDisplay progress, int total)
        {
            Files.ReadSafe(source);
            Files.NoReparse(destination);
            var text = new StringBuilder();
            object gate = new object();
            using (var process = new Process())
            {
                process.StartInfo = new ProcessStartInfo {
                    FileName = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "xcopy.exe"),
                    Arguments = "\"" + System.IO.Path.Combine(source, "*") + "\" \"" + destination + "\" /E /I /H /Y /G /Q",
                    UseShellExecute = false, CreateNoWindow = true,
                    RedirectStandardOutput = true, RedirectStandardError = true
                };
                DataReceivedEventHandler collect = (sender, e) => {
                    if (e.Data != null) lock (gate) { if (text.Length < 16000) text.AppendLine(e.Data); }
                };
                process.OutputDataReceived += collect;
                process.ErrorDataReceived += collect;
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                while (!process.WaitForExit(100))
                    if (progress != null) progress.Update("兼容方式复制（xcopy /G）", 0, total);
                process.WaitForExit();
                return new TransferResult { ExitCode = process.ExitCode, Output = text.ToString(), Method = "xcopy", TotalFiles = total };
            }
        }
    }

    // 仅显示本次前台启动的进度；不注册后台任务，不写入系统设置。
    public sealed class ProgressDisplay : IDisposable
    {
        private readonly object gate = new object();
        private readonly ManualResetEvent closed = new ManualResetEvent(false);
        private readonly Stopwatch timer = Stopwatch.StartNew();
        private readonly Thread thread;
        private readonly bool disabled;
        private readonly int delay;
        private string phase = "正在准备运行时";
        private int completed, total, shown;
        public int ShowCount { get { return Volatile.Read(ref shown); } }
        public string DisplayError { get; private set; }
        public ProgressDisplay(bool noUi) : this(noUi, 2000) { }
        public ProgressDisplay(bool noUi, int delayMilliseconds)
        {
            disabled = noUi;
            delay = delayMilliseconds;
            if (!disabled)
            {
                thread = new Thread(() => {
                    try { Run(); }
                    catch (Exception error) { DisplayError = error.Message; }
                }) { IsBackground = true, Name = "运行时准备进度" };
                thread.SetApartmentState(ApartmentState.STA);
                thread.Start();
            }
        }
        public void Update(string value, int done, int count)
        { lock (gate) { phase = value; completed = done; total = count; } }
        public string Caption()
        {
            lock (gate) return phase + "\r\n文件：" + completed + " / " + total + "\r\n耗时：" + timer.Elapsed.TotalSeconds.ToString("F1") + " 秒";
        }
        private void Run()
        {
            while (timer.ElapsedMilliseconds < delay) if (closed.WaitOne(50)) return;
            if (closed.WaitOne(0)) return;
            using (var form = new Form())
            using (var tick = new System.Windows.Forms.Timer())
            {
                form.Text = "ChatGPT 自动修复启动器";
                form.ClientSize = new Size(420, 145);
                form.StartPosition = FormStartPosition.CenterScreen;
                form.FormBorderStyle = FormBorderStyle.FixedDialog;
                form.ControlBox = false;
                form.MaximizeBox = false;
                form.MinimizeBox = false;
                form.Font = new Font("Microsoft YaHei UI", 10);
                var label = new Label { Left = 18, Top = 16, Width = 384, Height = 80 };
                var bar = new ProgressBar { Left = 18, Top = 108, Width = 384, Height = 18 };
                form.Controls.Add(label); form.Controls.Add(bar);
                tick.Interval = 100;
                tick.Tick += (sender, e) => {
                    if (closed.WaitOne(0)) { form.Close(); return; }
                    label.Text = Caption();
                    lock (gate)
                    {
                        if (total > 0 && completed > 0)
                        { bar.Style = ProgressBarStyle.Continuous; bar.Maximum = total; bar.Value = Math.Min(total, completed); }
                        else bar.Style = ProgressBarStyle.Marquee;
                    }
                };
                form.Shown += (sender, e) => Interlocked.Increment(ref shown);
                label.Text = Caption();
                tick.Start();
                Application.Run(form);
            }
        }
        public void Dispose()
        {
            closed.Set();
            if (thread != null) thread.Join();
            closed.Dispose();
        }
    }
}
