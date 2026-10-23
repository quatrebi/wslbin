// wslbin: utilities that have a version of their own for Windows.

using System;
using System.Collections.Generic;

namespace Wslbin
{
    // data/native-versions.txt, built into the .exe: "<utility> <winget package id>" a line. --doctor
    // names the package for a wrapper of such a utility. It is advice, not a problem: the version from WSL
    // works too, and may be the one the user wants.
    internal static class NativeVersions
    {
        // utility -> winget package id; the names compare as Windows compares file names, without case
        public static Dictionary<string, string> Load()
        {
            var packages = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string raw in Resources.Text(Resources.NativeVersions).Split('\n'))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line[0] == '#') continue;
                string[] fields = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                if (fields.Length == 2) packages[fields[0]] = fields[1];
            }
            return packages;
        }
    }
}
