// Agenda.exe - inicia a Agenda de Compromissos em segundo plano (ícone na bandeja), sem janela de console.
// Compilado com o compilador C# que já vem no Windows (.NET Framework 4):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /win32icon:fonte\agenda.ico /out:Agenda.exe fonte\Agenda.cs
using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Agenda de Compromissos")]
[assembly: System.Reflection.AssemblyProduct("Agenda de Compromissos")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]

static class Programa
{
    [STAThread]
    static void Main(string[] args)
    {
        string pasta = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(pasta, "bandeja.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Arquivo não encontrado:\n" + script + "\n\nMantenha o Agenda.exe na mesma pasta da agenda.",
                "Agenda de Compromissos", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        string extra = args.Length > 0 ? " " + string.Join(" ", args) : "";
        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"" + extra);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.WorkingDirectory = pasta;
        Process.Start(psi);
    }
}
