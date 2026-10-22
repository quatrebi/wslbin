// wslbin: what wslbin learns about WSL: calls to wsl.exe whose output it reads, and the registry.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace Wslbin
{
    internal sealed class Distro
    {
        public string Name;
        public bool IsDefault;
        public string State;
        public string Version;
    }

    internal sealed class WslResult
    {
        public int ExitCode;
        public string Output = "";
        public string Error = "";
    }

    // What wslbin learns about WSL itself: calls to wsl.exe whose output it reads (management commands
    // and Tab completion; a wrapper never captures anything), and the registry.
    internal static class WslQuery
    {
        // The advice for every message that says WSL itself is missing.
        public const string InstallFix = "run 'wsl --install' as administrator";
        public const string NotInstalled = "WSL is not installed (wsl.exe answers with its usage text)";

        // Whether WSL has a distribution for this user. WSL keeps one registry key each under
        // HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss, with the name in DistributionName (WSL 1,
        // WSL 2 and the Store version alike). Asked only after wsl.exe failed. The test build replaces it.
        internal static Func<bool> HasDistribution = RegistryHasDistribution;

        const string LxssKey = @"Software\Microsoft\Windows\CurrentVersion\Lxss";

        // A registry that cannot be read says nothing, and then the exit code of the utility stands.
        static bool RegistryHasDistribution()
        {
            try
            {
                using (RegistryKey lxss = Registry.CurrentUser.OpenSubKey(LxssKey))
                {
                    if (lxss == null) return false;
                    foreach (string name in lxss.GetSubKeyNames())
                    {
                        using (RegistryKey distro = lxss.OpenSubKey(name))
                        {
                            if (distro != null && distro.GetValue("DistributionName") is string) return true;
                        }
                    }
                    return false;
                }
            }
            catch (System.Security.SecurityException) { return true; }
            catch (UnauthorizedAccessException) { return true; }
            catch (IOException) { return true; }
        }

        // bash -c <script> in the configured distribution.
        public static WslResult RunBash(Config cfg, string script)
        {
            return RunBash(cfg, script, new List<string>(), Timeout.Infinite);
        }

        // With positional parameters: the first becomes $0, the next $1, ... A call that takes longer
        // than timeoutMs is stopped and reported as an error.
        public static WslResult RunBash(Config cfg, string script, IList<string> positional, int timeoutMs)
        {
            return Capture(Launcher.WslArguments(cfg, script, positional), timeoutMs);
        }

        // wsl.exe's own commands, like -l -v.
        public static WslResult Own(string arguments)
        {
            return Capture(arguments, Timeout.Infinite);
        }

        static WslResult Capture(string arguments, int timeoutMs)
        {
            var psi = new ProcessStartInfo(Launcher.FindWsl(), arguments);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            try
            {
                using (Process process = Process.Start(psi))
                {
                    process.StandardInput.Close();
                    Task<byte[]> error = ReadAllAsync(process.StandardError.BaseStream);
                    Task<byte[]> output = ReadAllAsync(process.StandardOutput.BaseStream);
                    if (!process.WaitForExit(timeoutMs))
                    {
                        try { process.Kill(); }
                        catch (InvalidOperationException) { }
                        catch (Win32Exception) { }
                        throw new WslbinException("wsl.exe did not answer within " + timeoutMs / 1000 + " seconds");
                    }
                    return new WslResult { ExitCode = process.ExitCode, Output = Decode(output.Result), Error = Decode(error.Result) };
                }
            }
            catch (Win32Exception ex)
            {
                throw new WslbinException("cannot start wsl.exe: " + ex.Message);
            }
        }

        static Task<byte[]> ReadAllAsync(Stream stream)
        {
            return Task.Run(() =>
            {
                var buffer = new MemoryStream();
                stream.CopyTo(buffer);
                return buffer.ToArray();
            });
        }

        // bash writes UTF-8. wsl.exe writes its own messages (its errors, its usage text, -l -v) in
        // UTF-16, or in UTF-8 when WSL_UTF8=1 is set. UTF-16 text always has NUL bytes (every ASCII
        // letter, blank and line break carries one) and the text of bash here never has, which tells
        // the two apart. A message of wsl.exe may come in front of what bash writes on the same stream:
        // the UTF-16 part then ends with the last line break in UTF-16 (0A 00) after which no NUL follows.
        internal static string Decode(byte[] bytes)
        {
            if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) return Decode16(bytes, 2, bytes.Length - 2);
            if (Array.IndexOf(bytes, (byte)0) < 0) return Decode8(bytes, 0, bytes.Length);
            int split = -1;
            for (int i = 0; i + 1 < bytes.Length; i += 2)
            {
                if (bytes[i] == 0x0A && bytes[i + 1] == 0) split = i + 2;
            }
            if (split > 0 && Array.IndexOf(bytes, (byte)0, split) < 0)
                return Decode16(bytes, 0, split) + Decode8(bytes, split, bytes.Length - split);
            return Decode16(bytes, 0, bytes.Length);
        }

        static string Decode16(byte[] bytes, int start, int count)
        {
            return Encoding.Unicode.GetString(bytes, start, count);
        }

        static string Decode8(byte[] bytes, int start, int count)
        {
            if (count >= 3 && bytes[start] == 0xEF && bytes[start + 1] == 0xBB && bytes[start + 2] == 0xBF)
            {
                start += 3;
                count -= 3;
            }
            return new UTF8Encoding(false).GetString(bytes, start, count);
        }

        // Whether wsl.exe printed its usage text instead of doing what it was asked. That is how the
        // wsl.exe of Windows 10 answers every command when WSL is not installed (seen in Windows
        // Sandbox; exit code 1). The text is in the language of Windows, but the names of the options are
        // not translated. Only a failed call counts: Tab completion may well offer these three names as
        // candidates (dpkg has all of them).
        public static bool IsUsage(WslResult r)
        {
            if (r.ExitCode == 0) return false;
            string text = r.Output + "\n" + r.Error;
            return text.Contains("--install") && text.Contains("--list") && text.Contains("--status");
        }

        // ": what went wrong", for a message about a call that failed: what wsl.exe or bash wrote,
        // standard error first, on one line.
        public static string Detail(WslResult r)
        {
            if (IsUsage(r)) return ": " + NotInstalled + " (fix: " + InstallFix + ")";
            string text = OneLine(r.Error);
            if (text.Length == 0) text = OneLine(r.Output);
            return text.Length == 0 ? " (exit code " + r.ExitCode + ")" : ": " + text;
        }

        static string OneLine(string text)
        {
            return text.Replace("\r", "").Trim().Replace("\n", " ");
        }

        // "wsl -l -v": a header, then "* Ubuntu-24.04   Running   2" or "  Debian   Stopped   2", one
        // distribution a line: the name, the state (more than one word where it is translated) and the
        // version. A name is letters, digits and . _ - (the rule of WSL itself, s_ValidateDistroName), and
        // a line of the list is indented by two blanks at most, so neither the header nor a message nor
        // a line of the usage text is taken for one. Throws when WSL is not installed.
        public static List<Distro> Distros()
        {
            WslResult r = Own("-l -v");
            if (IsUsage(r)) throw new WslbinException(NotInstalled);
            var list = new List<Distro>();
            foreach (string raw in r.Output.Replace("\r", "").Split('\n'))
            {
                string line = raw.TrimStart('﻿').TrimEnd();
                bool isDefault = line.StartsWith("*", StringComparison.Ordinal);
                if (isDefault) line = line.Substring(1);
                string trimmed = line.TrimStart(' ', '\t');
                if (line.Length - trimmed.Length > 2) continue;
                string[] t = trimmed.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (t.Length < 3 || !IsDistroName(t[0])) continue;
                string version = t[t.Length - 1];
                if (version != "1" && version != "2") continue;
                list.Add(new Distro
                {
                    Name = t[0],
                    IsDefault = isDefault,
                    State = string.Join(" ", t, 1, t.Length - 2),
                    Version = version
                });
            }
            return list;
        }

        static bool IsDistroName(string s)
        {
            foreach (char c in s)
            {
                bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
                if (!ok) return false;
            }
            return s.Length > 0;
        }

        // Whether each name is a command in WSL (command -v). Throws when bash cannot be run at all.
        public static Dictionary<string, bool> Presence(Config cfg, IList<string> names)
        {
            var result = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
            if (names.Count == 0) return result;

            var words = new List<string>();
            foreach (string n in names) words.Add(Bash.Literal(n));
            string script = cfg.PathPrefix() + "for n in " + string.Join(" ", words) +
                "; do if command -v \"$n\" >/dev/null 2>&1; then echo \"ok $n\"; else echo \"missing $n\"; fi; done";
            WslResult r = RunBash(cfg, script);
            foreach (string line in r.Output.Replace("\r", "").Split('\n'))
            {
                if (line.StartsWith("ok ", StringComparison.Ordinal)) result[line.Substring(3)] = true;
                else if (line.StartsWith("missing ", StringComparison.Ordinal)) result[line.Substring(8)] = false;
            }
            if (result.Count == 0) throw new WslbinException("cannot run bash in WSL" + Detail(r));
            return result;
        }

        public static bool HasAptGet(Config cfg)
        {
            return RunBash(cfg, "command -v apt-get >/dev/null 2>&1").ExitCode == 0;
        }

        // The apt package that provides a command: command-not-found knows (it prints to stderr),
        // else a package of the same name, else null.
        public static string SuggestPackage(Config cfg, string command)
        {
            WslResult r = RunBash(cfg, "/usr/lib/command-not-found --no-failure-msg " + Bash.Literal(command) + " 2>&1");
            foreach (string raw in (r.Output + "\n" + r.Error).Replace("\r", "").Split('\n'))
            {
                string line = raw.Trim();
                if (!line.StartsWith("sudo apt install ", StringComparison.Ordinal)) continue;
                string rest = line.Substring("sudo apt install ".Length).Trim();
                int space = rest.IndexOfAny(new[] { ' ', '\t' });
                string package = space < 0 ? rest : rest.Substring(0, space);
                if (IsPackageName(package)) return package;
            }
            r = RunBash(cfg, "apt-cache policy " + Bash.Literal(command) + " 2>/dev/null | grep -m1 Candidate:");
            if (r.Output.Contains("Candidate:") && !r.Output.Contains("(none)") && IsPackageName(command)) return command;
            return null;
        }

        static bool IsPackageName(string s)
        {
            if (s.Length < 2) return false;
            foreach (char c in s)
            {
                bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '+' || c == '-' || c == '.';
                if (!ok) return false;
            }
            return s[0] != '-' && s[0] != '.' && s[0] != '+';
        }
    }
}
