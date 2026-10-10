using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections;
using System.Collections.Generic;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;
using System.Runtime.InteropServices;

namespace ChatGPTRuntimeLauncher
{
    public sealed class Entry
    {
        public string Path { get; set; }
        public bool Directory { get; set; }
        public long Length { get; set; }
        public long Modified { get; set; }
        public long Created { get; set; }
        public string Hash { get; set; }
    }

    public static class Files
    {
        private static string packageReadRoot;

        // MSIX 可能通过系统联接点安装到其他卷；仅当前已注册包根的只读访问允许此结构。
        public static void SetPackageReadRoot(string root) { packageReadRoot = Full(root); }

        public static void ReadSafe(string path)
        {
            string current = Full(path);
            if (packageReadRoot == null || !(current == packageReadRoot || current.StartsWith(packageReadRoot + "\\", StringComparison.OrdinalIgnoreCase)))
            { NoReparse(path); return; }
            while (!String.Equals(current, packageReadRoot, StringComparison.OrdinalIgnoreCase))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("包内存在未允许的重解析点：" + current);
                current = System.IO.Path.GetDirectoryName(current);
            }
        }

        public static string ReadWithin(string root, string path)
        {
            string p = Full(path);
            if (!p.StartsWith(Full(root) + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("读取路径超出当前安装包：" + p);
            ReadSafe(p);
            return p;
        }
        public static string Full(string path)
        {
            return System.IO.Path.GetFullPath(path).TrimEnd('\\', '/');
        }

        // 检查现有的每一级父目录，防止联接点把操作引向预期目录以外。
        public static void NoReparse(string path)
        {
            string current = System.IO.Path.GetFullPath(path);
            while (!String.IsNullOrEmpty(current))
            {
                try
                {
                    if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                        throw new IOException("拒绝处理重解析点：" + current);
                }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
                string parent = System.IO.Path.GetDirectoryName(current.TrimEnd('\\', '/'));
                if (String.Equals(parent, current, StringComparison.OrdinalIgnoreCase)) break;
                current = parent;
            }
        }

        public static string Within(string root, string path, bool allowRoot)
        {
            string r = Full(root), p = Full(path);
            if (!(allowRoot && String.Equals(r, p, StringComparison.OrdinalIgnoreCase)) &&
                !p.StartsWith(r + "\\", StringComparison.OrdinalIgnoreCase))
                throw new IOException("路径不在允许的目录内：" + p);
            NoReparse(p);
            return p;
        }

        public static string Hash(string path)
        {
            ReadSafe(path);
            using (var sha = SHA256.Create())
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
                return Hex(sha.ComputeHash(stream));
        }

        public static string HashText(string value)
        {
            using (var sha = SHA256.Create()) return Hex(sha.ComputeHash(Encoding.UTF8.GetBytes(value)));
        }

        private static string Hex(byte[] data)
        {
            return BitConverter.ToString(data).Replace("-", "").ToLowerInvariant();
        }

        public static Entry[] Inventory(string root, bool hashes)
        {
            ReadSafe(root);
            if (!System.IO.Directory.Exists(root)) throw new DirectoryNotFoundException(root);
            string full = Full(root);
            var result = new List<Entry>();
            Visit(full, full, hashes, result);
            return result.OrderBy(e => e.Path, StringComparer.Ordinal).ToArray();
        }

        private static void Visit(string root, string current, bool hashes, List<Entry> result)
        {
            foreach (string path in System.IO.Directory.EnumerateFileSystemEntries(current))
            {
                FileAttributes attributes = File.GetAttributes(path);
                if ((attributes & FileAttributes.ReparsePoint) != 0)
                    throw new IOException("目录中存在重解析点：" + path);
                bool isDir = (attributes & FileAttributes.Directory) != 0;
                var item = new Entry {
                    Path = path.Substring(root.Length + 1).Replace('\\', '/'),
                    Directory = isDir,
                    Length = isDir ? 0 : new FileInfo(path).Length,
                    Modified = File.GetLastWriteTimeUtc(path).Ticks,
                    Created = File.GetCreationTimeUtc(path).Ticks
                };
                if (!isDir && hashes)
                {
                    item.Hash = Hash(path);
                    if (new FileInfo(path).Length != item.Length || File.GetLastWriteTimeUtc(path).Ticks != item.Modified)
                        throw new IOException("校验期间文件发生变化：" + path);
                }
                result.Add(item);
                if (isDir) Visit(root, path, hashes, result);
            }
        }

        public static string Fingerprint(Entry[] entries)
        {
            var value = new StringBuilder();
            foreach (Entry e in entries)
                value.Append(e.Path).Append('\0').Append(e.Directory ? 'D' : 'F').Append('\0')
                    .Append(e.Length).Append('\0').Append(e.Modified).Append('\0').Append(e.Created).Append('\n');
            return HashText(value.ToString());
        }

        public static string RuntimeId(string source)
        {
            var value = new StringBuilder();
            foreach (string name in new[] { "manifest.json", "bin/node.exe", "bin/node_repl.exe" })
                value.Append(name).Append('\0').Append(Hash(System.IO.Path.Combine(source, name))).Append('\0');
            return HashText(value.ToString()).Substring(0, 16);
        }

        public static bool VerifyKeys(string target, string[] expected)
        {
            string[] names = { "manifest.json", "bin/node.exe", "bin/node_repl.exe" };
            if (expected == null || expected.Length != names.Length) return false;
            for (int i = 0; i < names.Length; i++)
            {
                string path = System.IO.Path.Combine(target, names[i]);
                if (!File.Exists(path) || !String.Equals(Hash(path), expected[i], StringComparison.Ordinal)) return false;
            }
            return System.IO.Directory.Exists(System.IO.Path.Combine(target, "bin", "node_modules"));
        }

        // 只要求源清单中的目录和文件齐全；应用自行生成的额外缓存不会触发复制。
        public static string[] Compare(string expectedJson, Entry[] actual)
        {
            var serializer = Serializer();
            Entry[] expected = serializer.Deserialize<Entry[]>(expectedJson);
            if (expected == null || expected.Length == 0) throw new IOException("源文件清单为空。");
            var found = actual.ToDictionary(e => e.Path, StringComparer.OrdinalIgnoreCase);
            var errors = new List<string>();
            foreach (Entry e in expected)
            {
                Entry a;
                if (!found.TryGetValue(e.Path, out a)) errors.Add("缺失：" + e.Path);
                else if (a.Directory != e.Directory || a.Length != e.Length) errors.Add("类型或大小不同：" + e.Path);
                else if (!e.Directory && (String.IsNullOrEmpty(e.Hash) || a.Hash != e.Hash)) errors.Add("内容不同：" + e.Path);
                if (errors.Count >= 12) break;
            }
            return errors.ToArray();
        }

        public static string ToJson(object value)
        {
            return Serializer().Serialize(value);
        }

        public static JavaScriptSerializer Serializer()
        {
            return new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024, RecursionLimit = 256 };
        }

        public static void AtomicText(string root, string destination, string contents)
        {
            Within(root, destination, false);
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(destination));
            string temp = destination + ".tmp-" + Guid.NewGuid().ToString("N");
            try
            {
                File.WriteAllText(temp, contents, new UTF8Encoding(false));
                Within(root, destination, false);
                if (File.Exists(destination)) File.Replace(temp, destination, null);
                else File.Move(temp, destination);
            }
            finally { if (File.Exists(temp)) { Within(root, temp, false); File.Delete(temp); } }
        }

        public static void Append(string root, string destination, string contents)
        {
            Within(root, destination, false);
            System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(destination));
            File.AppendAllText(destination, contents + Environment.NewLine, new UTF8Encoding(false));
        }

        public static long AvailableBytes(string path)
        {
            return new DriveInfo(System.IO.Path.GetPathRoot(System.IO.Path.GetFullPath(path))).AvailableFreeSpace;
        }
    }

    public static class Algorithm
    {
        public const string Id = "sha256-nul-manifest-node-repl-v1";

        // ASAR 仅作为数据读取；不执行安装包中的 JavaScript。
        public static string VerifyAsar(string path)
        {
            Files.ReadSafe(path);
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (var reader = new BinaryReader(stream, Encoding.UTF8))
            {
                uint size = reader.ReadUInt32(), headerSize = reader.ReadUInt32();
                uint payloadSize = reader.ReadUInt32(), jsonSize = reader.ReadUInt32();
                if (size != 4 || headerSize > 32 * 1024 * 1024 || jsonSize > headerSize ||
                    payloadSize + 4 != headerSize || 8L + headerSize > stream.Length)
                    throw new IOException("无法识别 ASAR 头部。");
                byte[] bytes = reader.ReadBytes((int)jsonSize);
                if (bytes.Length != jsonSize) throw new IOException("ASAR 头部不完整。");
                var tree = Files.Serializer().Deserialize<Dictionary<string, object>>(Encoding.UTF8.GetString(bytes));
                var entries = new List<KeyValuePair<string, Dictionary<string, object>>>();
                Walk(tree, "", entries);
                long dataStart = 8L + headerSize;
                foreach (var pair in entries)
                {
                    if (!pair.Key.StartsWith(".vite/build/", StringComparison.Ordinal) || !pair.Key.EndsWith(".js", StringComparison.Ordinal)) continue;
                    var entry = pair.Value;
                    if (!entry.ContainsKey("offset") || (entry.ContainsKey("unpacked") && Convert.ToBoolean(entry["unpacked"]))) continue;
                    long count = Convert.ToInt64(entry["size"]), offset = Convert.ToInt64(entry["offset"]);
                    if (count < 0 || count > 20 * 1024 * 1024 || offset < 0 || dataStart + offset + count > stream.Length) continue;
                    stream.Position = dataStart + offset;
                    string code = Encoding.UTF8.GetString(reader.ReadBytes((int)count));
                    if (!code.Contains("cua_node") || !code.Contains(".staging-") || !code.Contains("Bundled executable relocation failed")) continue;
                    if (VerifyCode(code)) return pair.Key;
                }
            }
            throw new IOException("当前安装包的 runtime ID 算法不在已验证规则内；已停止自动修复，未采用旧 staging 猜测目录。");
        }

        private static void Walk(Dictionary<string, object> node, string prefix, List<KeyValuePair<string, Dictionary<string, object>>> entries)
        {
            object value;
            if (!node.TryGetValue("files", out value)) return;
            foreach (var pair in (Dictionary<string, object>)value)
            {
                var child = (Dictionary<string, object>)pair.Value;
                string path = prefix + pair.Key;
                if (child.ContainsKey("files")) Walk(child, path + "/", entries);
                else entries.Add(new KeyValuePair<string, Dictionary<string, object>>(path, child));
            }
        }

        // 捕获并关联变量名，允许构建器改名；顺序、分隔符或截断规则变化则拒绝。
        public static bool VerifyCode(string code)
        {
            string ident = @"[$A-Za-z_][$\w]*";
            string quote = "[`'\"]";
            string list = @"(?<items>" + ident + @")=\[" + quote + @"manifest\.json" + quote + "," + quote + @"bin/node\.exe" + quote + "," + quote + @"bin/node_repl\.exe" + quote + @"\]\.map\((?<item>" + ident + @")=>(?<record>" + ident + @")\(\{(?<context>[^;]{1,700}?)\}\)\),(?<id>" + ident + @")=(?<combine>" + ident + @")\(\k<items>\)\.slice\(0,16\)";
            Match m = Regex.Match(code, list);
            if (!m.Success || !Regex.IsMatch(m.Groups["context"].Value, @"executableName:" + Regex.Escape(m.Groups["item"].Value) + @"(?:,|$)")) return false;
            string arguments, body = Function(code, m.Groups["combine"].Value, out arguments);
            if (body == null) return false;
            string pattern = @"\Alet\s+(?<h>" + ident + @")=\(0," + ident + @"\.createHash\)\(" + quote + "sha256" + quote + @"\);for\(let\s+(?<entry>" + ident + @")\s+of\s+" + Regex.Escape(arguments) + @"\)\k<h>\.update\(\k<entry>\.executableName\),\k<h>\.update\(" + quote + @"\\0" + quote + @"\),\k<h>\.update\(\k<entry>\.digest\),\k<h>\.update\(" + quote + @"\\0" + quote + @"\);return\s+\k<h>\.digest\(" + quote + "hex" + quote + @"\);?\z";
            if (!Regex.IsMatch(body.Trim(), pattern)) return false;
            string record = Function(code, m.Groups["record"].Value, out arguments);
            if (record == null || !record.Contains("statSync") || !record.Contains("sourcePath:")) return false;
            Match digest = Regex.Match(record, @"digest:(?<fn>" + ident + @")\(");
            if (!digest.Success) return false;
            string hasher = Function(code, digest.Groups["fn"].Value, out arguments);
            return hasher != null && Regex.IsMatch(hasher, @"createHash\)\(" + quote + "sha256" + quote + @"\)") &&
                hasher.Contains("readFileSync") && Regex.IsMatch(hasher, @"\.digest\(" + quote + "hex" + quote + @"\)");
        }

        private static string Function(string code, string name, out string arguments)
        {
            arguments = null;
            Match match = Regex.Match(code, @"function\s+" + Regex.Escape(name) + @"\(");
            if (!match.Success) return null;
            int argsStart = match.Index + match.Length;
            int bodyStart = code.IndexOf("){", argsStart, StringComparison.Ordinal);
            if (bodyStart < 0 || bodyStart - argsStart > 500) return null;
            arguments = code.Substring(argsStart, bodyStart - argsStart);
            int depth = 1, start = bodyStart + 2;
            char quote = '\0';
            for (int i = start; i < code.Length && i - start < 16000; i++)
            {
                char c = code[i];
                if (quote != '\0')
                {
                    if (c == '\\') { i++; continue; }
                    if (c == quote) quote = '\0';
                    continue;
                }
                if (c == '\'' || c == '"' || c == '`') { quote = c; continue; }
                if (c == '{') depth++;
                if (c == '}') depth--;
                if (depth == 0) return code.Substring(start, i - start);
            }
            return null;
        }

    }

    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IApplicationActivationManager
    {
        [PreserveSig]
        int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
    }

    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    internal class ApplicationActivationManager { }

    public static class Activation
    {
        public static uint Start(string appUserModelId)
        {
            var manager = (IApplicationActivationManager)new ApplicationActivationManager();
            try
            {
                uint pid;
                int result = manager.ActivateApplication(appUserModelId, null, 0, out pid);
                if (result < 0) Marshal.ThrowExceptionForHR(result);
                return pid;
            }
            finally { Marshal.ReleaseComObject(manager); }
        }
    }
}
