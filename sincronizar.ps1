<#
  Agenda de Compromissos - sincronização com calendários externos (Outlook / Google) via link ICS.
  Executado em segundo plano pelo servidor a cada 5 minutos (não precisa ser rodado manualmente).

  Lê os calendários cadastrados em dados\config.json, baixa cada link ICS, expande os eventos
  recorrentes e grava as ocorrências dos próximos dias em dados\externos.json. O servidor então
  incorpora esses eventos à agenda (somente leitura) para alarmes, avisos no celular e conflitos.
#>
param([int]$DiasAFrente = 60)

$ErrorActionPreference = 'Stop'
$Raiz       = Split-Path -Parent $MyInvocation.MyCommand.Path
$PastaDados = Join-Path $Raiz 'dados'
$ArqConfig  = Join-Path $PastaDados 'config.json'
$ArqSaida   = Join-Path $PastaDados 'externos.json'
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$Inv        = [Globalization.CultureInfo]::InvariantCulture
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- leitor ICS (RFC 5545) em C#
$codigo = @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.RegularExpressions;

namespace AgendaIcs
{
    public class Ocorrencia
    {
        public string Uid;
        public string Titulo;
        public DateTime Inicio;   // horário local deste computador
        public DateTime Fim;
        public bool Recorrente;   // pertence a uma série (RRULE ou ocorrência remarcada)
    }

    public class Resultado
    {
        public List<Ocorrencia> Ocorrencias = new List<Ocorrencia>();
        public int Eventos;
        public int DiaInteiro;
    }

    class Prop
    {
        public string Nome;
        public string Valor;
        public Dictionary<string, string> Params = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    }

    class Evento
    {
        public string Uid = "";
        public string Titulo = "";
        public Prop DtStart, DtEnd, Duration, RRule, RecurrenceId;
        public List<Prop> ExDates = new List<Prop>();
        public bool Cancelado;
    }

    class Fuso
    {
        public TimeZoneInfo Tz;
        public bool Utc;
        public bool TemFixo;
        public TimeSpan Fixo;

        public DateTime ParaLocal(DateTime d)
        {
            if (Utc) return DateTime.SpecifyKind(d, DateTimeKind.Utc).ToLocalTime();
            if (Tz != null)
            {
                try { return TimeZoneInfo.ConvertTime(DateTime.SpecifyKind(d, DateTimeKind.Unspecified), Tz, TimeZoneInfo.Local); }
                catch { return d; }
            }
            if (TemFixo) return DateTime.SpecifyKind(d - Fixo, DateTimeKind.Utc).ToLocalTime();
            return d;   // horário "flutuante": já é local
        }
    }

    public static class Leitor
    {
        // fusos IANA (Google) -> Windows (o Outlook já usa nomes do Windows)
        static readonly Dictionary<string, string> Iana = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            {"America/Sao_Paulo", "E. South America Standard Time"}, {"America/Bahia", "Bahia Standard Time"},
            {"America/Fortaleza", "SA Eastern Standard Time"}, {"America/Recife", "SA Eastern Standard Time"},
            {"America/Belem", "SA Eastern Standard Time"}, {"America/Maceio", "SA Eastern Standard Time"},
            {"America/Araguaina", "Tocantins Standard Time"}, {"America/Manaus", "SA Western Standard Time"},
            {"America/Cuiaba", "Central Brazilian Standard Time"}, {"America/Campo_Grande", "Central Brazilian Standard Time"},
            {"America/Porto_Velho", "SA Western Standard Time"}, {"America/Boa_Vista", "SA Western Standard Time"},
            {"America/Rio_Branco", "SA Pacific Standard Time"}, {"America/Noronha", "UTC-02"},
            {"America/Argentina/Buenos_Aires", "Argentina Standard Time"}, {"America/Buenos_Aires", "Argentina Standard Time"},
            {"America/Montevideo", "Montevideo Standard Time"}, {"America/Santiago", "Pacific SA Standard Time"},
            {"America/Asuncion", "Paraguay Standard Time"}, {"America/Bogota", "SA Pacific Standard Time"},
            {"America/Lima", "SA Pacific Standard Time"}, {"America/Mexico_City", "Central Standard Time (Mexico)"},
            {"America/New_York", "Eastern Standard Time"}, {"America/Chicago", "Central Standard Time"},
            {"America/Denver", "Mountain Standard Time"}, {"America/Los_Angeles", "Pacific Standard Time"},
            {"Europe/London", "GMT Standard Time"}, {"Europe/Lisbon", "GMT Standard Time"},
            {"Europe/Madrid", "Romance Standard Time"}, {"Europe/Paris", "Romance Standard Time"},
            {"Europe/Berlin", "W. Europe Standard Time"}, {"Europe/Rome", "W. Europe Standard Time"},
            {"Europe/Amsterdam", "W. Europe Standard Time"}, {"Asia/Tokyo", "Tokyo Standard Time"},
            {"Asia/Shanghai", "China Standard Time"}, {"Asia/Kolkata", "India Standard Time"},
            {"UTC", "UTC"}, {"Etc/UTC", "UTC"}, {"GMT", "UTC"}, {"Etc/GMT", "UTC"}, {"Z", "UTC"}
        };

        static readonly Regex RxDia = new Regex(@"^([+-]?\d{1,2})?(MO|TU|WE|TH|FR|SA|SU)$", RegexOptions.IgnoreCase);
        static readonly Regex RxDuracao = new Regex(@"^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$", RegexOptions.IgnoreCase);

        public static Resultado Ler(string texto, DateTime janelaIni, DateTime janelaFim)
        {
            var res = new Resultado();
            string t = texto.Replace("\r\n", "\n").Replace("\r", "\n");
            t = Regex.Replace(t, "\n[ \t]", "");               // desdobra linhas longas
            var eventos = new List<Evento>();
            var offsets = new Dictionary<string, TimeSpan>(StringComparer.OrdinalIgnoreCase);
            Evento atual = null;
            int ignorar = 0;
            string tzAtual = null;
            bool emStandard = false;

            foreach (string bruta in t.Split('\n'))
            {
                string l = bruta.TrimEnd();
                if (l.Length == 0) continue;
                Prop p = LerProp(l);
                if (p == null) continue;
                string n = p.Nome.ToUpperInvariant();
                string vu = p.Valor.Trim().ToUpperInvariant();

                if (n == "BEGIN")
                {
                    if (atual != null) { ignorar++; continue; }          // ex.: VALARM dentro do evento
                    if (vu == "VEVENT") atual = new Evento();
                    else if (vu == "STANDARD") emStandard = true;
                    continue;
                }
                if (n == "END")
                {
                    if (atual != null)
                    {
                        if (ignorar > 0) { ignorar--; continue; }
                        if (vu == "VEVENT") { eventos.Add(atual); atual = null; }
                        continue;
                    }
                    if (vu == "STANDARD") emStandard = false;
                    if (vu == "VTIMEZONE") tzAtual = null;
                    continue;
                }
                if (atual == null)
                {
                    if (n == "TZID") tzAtual = p.Valor.Trim().Trim('"');
                    else if (n == "TZOFFSETTO" && emStandard && tzAtual != null)
                    {
                        TimeSpan off;
                        if (TryOffset(p.Valor, out off)) offsets[tzAtual] = off;
                    }
                    continue;
                }
                if (ignorar > 0) continue;
                switch (n)
                {
                    case "UID": atual.Uid = p.Valor.Trim(); break;
                    case "SUMMARY": atual.Titulo = Desescapar(p.Valor); break;
                    case "DTSTART": atual.DtStart = p; break;
                    case "DTEND": atual.DtEnd = p; break;
                    case "DURATION": atual.Duration = p; break;
                    case "RRULE": atual.RRule = p; break;
                    case "RECURRENCE-ID": atual.RecurrenceId = p; break;
                    case "EXDATE": atual.ExDates.Add(p); break;
                    case "STATUS": if (vu == "CANCELLED") atual.Cancelado = true; break;
                }
            }

            // ocorrências alteradas individualmente (RECURRENCE-ID), por UID
            var alteradas = new Dictionary<string, HashSet<string>>();
            foreach (Evento ev in eventos)
            {
                if (ev.RecurrenceId == null) continue;
                DateTime w; Fuso f; bool di;
                if (!LerData(ev.RecurrenceId, offsets, out w, out f, out di)) continue;
                HashSet<string> hs;
                if (!alteradas.TryGetValue(ev.Uid, out hs)) { hs = new HashSet<string>(); alteradas[ev.Uid] = hs; }
                hs.Add(di ? Chave(w.Date) : Chave(f.ParaLocal(w)));
                hs.Add("D" + (di ? w.Date : f.ParaLocal(w)).ToString("yyyyMMdd"));
            }

            foreach (Evento ev in eventos)
            {
                if (ev.DtStart == null) continue;
                DateTime iniW; Fuso fz; bool diaInteiro;
                if (!LerData(ev.DtStart, offsets, out iniW, out fz, out diaInteiro)) continue;
                if (ev.RecurrenceId == null) res.Eventos++;
                if (diaInteiro) { res.DiaInteiro++; continue; }       // eventos de dia inteiro não têm horário
                if (ev.Cancelado) continue;

                DateTime iniLocal = fz.ParaLocal(iniW);
                TimeSpan dur = TimeSpan.Zero;
                if (ev.DtEnd != null)
                {
                    DateTime fimW; Fuso ff; bool fdi;
                    if (LerData(ev.DtEnd, offsets, out fimW, out ff, out fdi)) dur = ff.ParaLocal(fimW) - iniLocal;
                }
                else if (ev.Duration != null) dur = LerDuracao(ev.Duration.Valor);
                if (dur <= TimeSpan.Zero) dur = TimeSpan.FromMinutes(30);

                // ocorrência avulsa (inclui as ocorrências alteradas de uma série)
                if (ev.RRule == null || ev.RecurrenceId != null)
                {
                    Adicionar(res, ev, iniLocal, dur, janelaIni, janelaFim);
                    continue;
                }

                // exceções da série
                var exc = new HashSet<string>();
                foreach (Prop ex in ev.ExDates)
                {
                    foreach (string parte in ex.Valor.Split(','))
                    {
                        var px = new Prop(); px.Nome = ex.Nome; px.Valor = parte.Trim(); px.Params = ex.Params;
                        DateTime xw; Fuso xf; bool xdi;
                        if (!LerData(px, offsets, out xw, out xf, out xdi)) continue;
                        exc.Add(xdi ? "D" + xw.ToString("yyyyMMdd") : Chave(xf.ParaLocal(xw)));
                    }
                }
                HashSet<string> alt;
                alteradas.TryGetValue(ev.Uid, out alt);

                var regra = LerRegra(ev.RRule.Valor);
                string freq = Valor(regra, "FREQ", "").ToUpperInvariant();
                int intervalo = Math.Max(1, Inteiro(Valor(regra, "INTERVAL", "1"), 1));
                int count = Inteiro(Valor(regra, "COUNT", "0"), 0);
                DateTime? ate = null;
                string untilTxt = Valor(regra, "UNTIL", null);
                if (untilTxt != null)
                {
                    var pu = new Prop(); pu.Nome = "UNTIL"; pu.Valor = untilTxt;
                    DateTime uw; Fuso uf; bool udi;
                    if (LerData(pu, offsets, out uw, out uf, out udi))
                        ate = udi ? uw.Date.AddDays(1).AddTicks(-1) : (uf.Utc ? uf.ParaLocal(uw) : fz.ParaLocal(uw));
                }
                var byDay = new List<KeyValuePair<int, DayOfWeek>>();
                foreach (string d in Lista(Valor(regra, "BYDAY", "")))
                {
                    Match m = RxDia.Match(d);
                    if (m.Success) byDay.Add(new KeyValuePair<int, DayOfWeek>(m.Groups[1].Success ? int.Parse(m.Groups[1].Value) : 0, DiaSemana(m.Groups[2].Value)));
                }
                var byMonthDay = Inteiros(Valor(regra, "BYMONTHDAY", ""));
                var byMonth = Inteiros(Valor(regra, "BYMONTH", ""));
                var bySetPos = Inteiros(Valor(regra, "BYSETPOS", ""));

                int n = 0, guarda = 0;
                foreach (DateTime w in Candidatos(iniW, freq, intervalo, byDay, byMonthDay, byMonth, bySetPos))
                {
                    if (++guarda > 500000) break;
                    DateTime loc = fz.ParaLocal(w);
                    n++;
                    if (count > 0 && n > count) break;
                    if (ate.HasValue && loc > ate.Value) break;
                    if (loc > janelaFim) break;
                    if (exc.Contains(Chave(loc)) || exc.Contains("D" + loc.ToString("yyyyMMdd"))) continue;
                    if (alt != null && alt.Contains(Chave(loc))) continue;     // substituída por versão alterada
                    Adicionar(res, ev, loc, dur, janelaIni, janelaFim);
                }
            }
            return res;
        }

        static void Adicionar(Resultado res, Evento ev, DateTime ini, TimeSpan dur, DateTime janelaIni, DateTime janelaFim)
        {
            if (ini < janelaIni || ini > janelaFim) return;
            var o = new Ocorrencia();
            o.Uid = ev.Uid;
            o.Titulo = string.IsNullOrEmpty(ev.Titulo) ? "(sem título)" : ev.Titulo;
            o.Inicio = ini;
            o.Fim = ini + dur;
            o.Recorrente = ev.RRule != null || ev.RecurrenceId != null;
            res.Ocorrencias.Add(o);
        }

        // datas candidatas da regra de recorrência, em ordem crescente (no fuso do evento)
        static IEnumerable<DateTime> Candidatos(DateTime ini, string freq, int intervalo,
            List<KeyValuePair<int, DayOfWeek>> byDay, List<int> byMonthDay, List<int> byMonth, List<int> bySetPos)
        {
            TimeSpan hora = ini.TimeOfDay;
            if (freq == "DAILY")
            {
                for (long k = 0; ; k++)
                {
                    DateTime d = ini.Date.AddDays(k * intervalo);
                    if (d.Year > 2200) yield break;
                    if (byDay.Count > 0 && !byDay.Exists(x => x.Value == d.DayOfWeek)) continue;
                    if (byMonth.Count > 0 && !byMonth.Contains(d.Month)) continue;
                    if (byMonthDay.Count > 0 && !byMonthDay.Contains(d.Day)) continue;
                    yield return d + hora;
                }
            }
            else if (freq == "WEEKLY")
            {
                var dias = new List<DayOfWeek>();
                foreach (var bd in byDay) if (!dias.Contains(bd.Value)) dias.Add(bd.Value);
                if (dias.Count == 0) dias.Add(ini.DayOfWeek);
                dias.Sort((a, b) => (((int)a + 6) % 7).CompareTo(((int)b + 6) % 7));     // semana começa na segunda
                DateTime semana = ini.Date.AddDays(-(((int)ini.DayOfWeek + 6) % 7));
                for (long k = 0; ; k++)
                {
                    DateTime s = semana.AddDays(7 * k * intervalo);
                    if (s.Year > 2200) yield break;
                    foreach (DayOfWeek dw in dias)
                    {
                        DateTime d = s.AddDays(((int)dw + 6) % 7);
                        if (d < ini.Date) continue;
                        if (byMonth.Count > 0 && !byMonth.Contains(d.Month)) continue;
                        yield return d + hora;
                    }
                }
            }
            else if (freq == "MONTHLY")
            {
                DateTime m0 = new DateTime(ini.Year, ini.Month, 1);
                for (long k = 0; ; k++)
                {
                    DateTime m = m0.AddMonths((int)(k * intervalo));
                    if (m.Year > 2200) yield break;
                    if (byMonth.Count > 0 && !byMonth.Contains(m.Month)) continue;
                    foreach (DateTime d in DiasDoMes(m, byDay, byMonthDay, bySetPos, ini.Day))
                        if (d >= ini.Date) yield return d + hora;
                }
            }
            else if (freq == "YEARLY")
            {
                var meses = byMonth.Count > 0 ? new List<int>(byMonth) : new List<int> { ini.Month };
                meses.Sort();
                for (long k = 0; ; k++)
                {
                    int ano = ini.Year + (int)(k * intervalo);
                    if (ano > 2200) yield break;
                    foreach (int mes in meses)
                        foreach (DateTime d in DiasDoMes(new DateTime(ano, mes, 1), byDay, byMonthDay, bySetPos, ini.Day))
                            if (d >= ini.Date) yield return d + hora;
                }
            }
            else
            {
                yield return ini;   // frequência não suportada (ex.: HOURLY): só a primeira ocorrência
            }
        }

        static List<DateTime> DiasDoMes(DateTime m, List<KeyValuePair<int, DayOfWeek>> byDay, List<int> byMonthDay, List<int> bySetPos, int diaPadrao)
        {
            int nd = DateTime.DaysInMonth(m.Year, m.Month);
            var r = new List<DateTime>();
            foreach (int md in byMonthDay)
            {
                int d = md > 0 ? md : nd + md + 1;
                if (d >= 1 && d <= nd) r.Add(new DateTime(m.Year, m.Month, d));
            }
            if (byDay.Count > 0)
            {
                var porDia = new List<DateTime>();
                foreach (var bd in byDay)
                {
                    var todos = new List<DateTime>();
                    for (int d = 1; d <= nd; d++)
                    {
                        var x = new DateTime(m.Year, m.Month, d);
                        if (x.DayOfWeek == bd.Value) todos.Add(x);
                    }
                    if (bd.Key == 0) porDia.AddRange(todos);
                    else
                    {
                        int idx = bd.Key > 0 ? bd.Key - 1 : todos.Count + bd.Key;
                        if (idx >= 0 && idx < todos.Count) porDia.Add(todos[idx]);
                    }
                }
                r = byMonthDay.Count > 0 ? r.FindAll(x => porDia.Contains(x)) : porDia;
            }
            if (byMonthDay.Count == 0 && byDay.Count == 0 && diaPadrao <= nd) r.Add(new DateTime(m.Year, m.Month, diaPadrao));
            var unicos = new List<DateTime>();
            foreach (var x in r) if (!unicos.Contains(x)) unicos.Add(x);
            unicos.Sort();
            if (bySetPos.Count > 0)
            {
                var sel = new List<DateTime>();
                foreach (int pos in bySetPos)
                {
                    int idx = pos > 0 ? pos - 1 : unicos.Count + pos;
                    if (idx >= 0 && idx < unicos.Count && !sel.Contains(unicos[idx])) sel.Add(unicos[idx]);
                }
                sel.Sort();
                return sel;
            }
            return unicos;
        }

        // ------------------------------------------------------------ utilidades
        static Prop LerProp(string l)
        {
            bool aspas = false;
            int dp = -1;
            for (int i = 0; i < l.Length; i++)
            {
                char c = l[i];
                if (c == '"') aspas = !aspas;
                else if (c == ':' && !aspas) { dp = i; break; }
            }
            if (dp <= 0) return null;
            var p = new Prop();
            p.Valor = l.Substring(dp + 1);
            var partes = new List<string>();
            var atual = new System.Text.StringBuilder();
            aspas = false;
            foreach (char c in l.Substring(0, dp))
            {
                if (c == '"') { aspas = !aspas; atual.Append(c); }
                else if (c == ';' && !aspas) { partes.Add(atual.ToString()); atual.Length = 0; }
                else atual.Append(c);
            }
            partes.Add(atual.ToString());
            p.Nome = partes[0].Trim();
            for (int k = 1; k < partes.Count; k++)
            {
                int eq = partes[k].IndexOf('=');
                if (eq > 0) p.Params[partes[k].Substring(0, eq).Trim()] = partes[k].Substring(eq + 1).Trim().Trim('"');
            }
            return p;
        }

        static bool LerData(Prop p, Dictionary<string, TimeSpan> offsets, out DateTime valor, out Fuso fuso, out bool diaInteiro)
        {
            valor = DateTime.MinValue; fuso = new Fuso(); diaInteiro = false;
            string v = p.Valor.Trim();
            string tipo;
            p.Params.TryGetValue("VALUE", out tipo);
            if (v.Length == 8 || (tipo != null && tipo.ToUpperInvariant() == "DATE"))
            {
                diaInteiro = true;
                return DateTime.TryParseExact(v.Substring(0, Math.Min(8, v.Length)), "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out valor);
            }
            bool z = v.EndsWith("Z", StringComparison.OrdinalIgnoreCase);
            if (z) v = v.Substring(0, v.Length - 1);
            string[] formatos = { "yyyyMMdd'T'HHmmss", "yyyyMMdd'T'HHmm" };
            if (!DateTime.TryParseExact(v, formatos, CultureInfo.InvariantCulture, DateTimeStyles.None, out valor)) return false;
            if (z) { fuso.Utc = true; return true; }
            string tzid;
            if (p.Params.TryGetValue("TZID", out tzid)) Resolver(tzid, offsets, fuso);
            return true;
        }

        static void Resolver(string tzid, Dictionary<string, TimeSpan> offsets, Fuso fuso)
        {
            string id = tzid.Trim().Trim('"');
            if (id.StartsWith("/"))      // ex.: /mozilla.org/20050126_1/America/Sao_Paulo
            {
                Match mi = Regex.Match(id, @"([A-Za-z_]+/[A-Za-z_\-]+)$");
                if (mi.Success) id = mi.Groups[1].Value;
            }
            try { fuso.Tz = TimeZoneInfo.FindSystemTimeZoneById(id); return; } catch { }
            string win;
            if (Iana.TryGetValue(id, out win)) { try { fuso.Tz = TimeZoneInfo.FindSystemTimeZoneById(win); return; } catch { } }
            TimeSpan off;
            if (offsets.TryGetValue(tzid.Trim().Trim('"'), out off)) { fuso.TemFixo = true; fuso.Fixo = off; return; }
            // desconhecido: considera horário local
        }

        static bool TryOffset(string v, out TimeSpan off)
        {
            off = TimeSpan.Zero;
            Match m = Regex.Match(v.Trim(), @"^([+-])(\d{2})(\d{2})(\d{2})?$");
            if (!m.Success) return false;
            off = new TimeSpan(int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value), m.Groups[4].Success ? int.Parse(m.Groups[4].Value) : 0);
            if (m.Groups[1].Value == "-") off = off.Negate();
            return true;
        }

        static TimeSpan LerDuracao(string v)
        {
            Match m = RxDuracao.Match(v.Trim());
            if (!m.Success) return TimeSpan.Zero;
            Func<int, int> g = i => m.Groups[i].Success ? int.Parse(m.Groups[i].Value) : 0;
            var t = new TimeSpan(g(2) * 7 + g(3), g(4), g(5), g(6));
            return m.Groups[1].Value == "-" ? t.Negate() : t;
        }

        static Dictionary<string, string> LerRegra(string v)
        {
            var r = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (string parte in v.Split(';'))
            {
                int eq = parte.IndexOf('=');
                if (eq > 0) r[parte.Substring(0, eq).Trim()] = parte.Substring(eq + 1).Trim();
            }
            return r;
        }

        static string Valor(Dictionary<string, string> d, string k, string padrao) { string v; return d.TryGetValue(k, out v) ? v : padrao; }
        static int Inteiro(string s, int padrao) { int v; return int.TryParse(s, out v) ? v : padrao; }
        static List<string> Lista(string s)
        {
            var r = new List<string>();
            foreach (string x in s.Split(',')) if (x.Trim().Length > 0) r.Add(x.Trim());
            return r;
        }
        static List<int> Inteiros(string s)
        {
            var r = new List<int>();
            foreach (string x in Lista(s)) { int v; if (int.TryParse(x, out v)) r.Add(v); }
            return r;
        }
        static DayOfWeek DiaSemana(string s)
        {
            switch (s.ToUpperInvariant())
            {
                case "MO": return DayOfWeek.Monday;
                case "TU": return DayOfWeek.Tuesday;
                case "WE": return DayOfWeek.Wednesday;
                case "TH": return DayOfWeek.Thursday;
                case "FR": return DayOfWeek.Friday;
                case "SA": return DayOfWeek.Saturday;
                default: return DayOfWeek.Sunday;
            }
        }
        static string Chave(DateTime d) { return d.ToString("yyyyMMddHHmm"); }
        static string Desescapar(string s)
        {
            return s.Replace("\\n", " ").Replace("\\N", " ").Replace("\\,", ",").Replace("\\;", ";").Replace("\\\\", "\\").Trim();
        }
    }
}
'@
Add-Type -TypeDefinition $codigo -Language CSharp

# ---------------------------------------------------------------- sincronização
function Get-IdOcorrencia([string]$calId, [string]$uid, [datetime]$inicio) {
    $md5 = [Security.Cryptography.MD5]::Create()
    $h = $md5.ComputeHash($Utf8.GetBytes("$calId|$uid|$($inicio.ToString('yyyyMMddHHmm', $Inv))"))
    return (New-Object Guid (, $h)).ToString()
}

function Get-TextoIcs([string]$url) {
    $u = $url.Trim()
    if ($u -match '^webcals?://') { $u = 'https://' + ($u -replace '^webcals?://', '') }
    $wc = New-Object Net.WebClient
    $wc.Headers['User-Agent'] = 'AgendaCompromissos/1.0'
    $wc.Headers['Accept'] = 'text/calendar, */*'
    $bytes = $wc.DownloadData($u)
    $texto = $Utf8.GetString($bytes)
    if ($texto -notmatch 'BEGIN:VCALENDAR') {
        throw 'O link não devolveu um calendário (ICS). Confira se é o endereço "iCal"/ICS e se a publicação está ativa.'
    }
    return $texto
}

$config = $null
if (Test-Path $ArqConfig) { $config = [IO.File]::ReadAllText($ArqConfig, $Utf8) | ConvertFrom-Json }
$calendarios = @($config.calendarios | Where-Object { $_ -and $_.ativo })

# Exclusões (seção "exclusoes" do config.json): eventos importados que nunca entram na agenda.
#   [{ "titulo": "RESERVADO", "somenteRecorrentes": true, "calendarioId": null }]
#   titulo: comparado sem diferenciar maiúsculas/minúsculas e espaços nas pontas
#   somenteRecorrentes: true = só ocorrências de séries; calendarioId: null/vazio = todos os calendários
$exclusoes = @($config.exclusoes | Where-Object { $_ -and $_.titulo })
function Test-Excluido($o, $calId) {
    foreach ($x in $exclusoes) {
        if ($x.calendarioId -and $x.calendarioId -ne $calId) { continue }
        if ($x.somenteRecorrentes -and -not $o.Recorrente) { continue }
        if ([string]::Equals(([string]$o.Titulo).Trim(), ([string]$x.titulo).Trim(), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$janelaIni = (Get-Date).Date
$janelaFim = $janelaIni.AddDays($DiasAFrente + 1).AddTicks(-1)
$eventos = New-Object System.Collections.ArrayList
$status = New-Object System.Collections.ArrayList

foreach ($cal in $calendarios) {
    $st = [ordered]@{ id = $cal.id; nome = $cal.nome; ok = $false; erro = $null; eventos = 0; ocorrencias = 0; diaInteiro = 0; excluidos = 0; sincronizadoEm = (Get-Date).ToString('s') }
    try {
        $r = [AgendaIcs.Leitor]::Ler((Get-TextoIcs $cal.url), $janelaIni, $janelaFim)
        $aviso = if ($null -ne $cal.avisoMinutos) { [int]$cal.avisoMinutos } else { 10 }
        foreach ($o in $r.Ocorrencias) {
            if (Test-Excluido $o $cal.id) { $st.excluidos++; continue }
            $ini = $o.Inicio; $fim = $o.Fim
            $fimTxt = if ($fim.Date -gt $ini.Date) { '23:59' } else { $fim.ToString('HH:mm', $Inv) }
            $iniTxt = $ini.ToString('HH:mm', $Inv)
            if ($fimTxt -le $iniTxt) { continue }
            [void]$eventos.Add([ordered]@{
                id = Get-IdOcorrencia $cal.id $o.Uid $ini; calendarioId = $cal.id; origem = $cal.nome
                titulo = $o.Titulo; data = $ini.ToString('yyyy-MM-dd', $Inv); inicio = $iniTxt; fim = $fimTxt; avisoMinutos = $aviso
            })
            $st.ocorrencias++
        }
        $st.ok = $true; $st.eventos = $r.Eventos; $st.diaInteiro = $r.DiaInteiro
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $st.erro = $msg
    }
    [void]$status.Add($st)
}

$saida = [ordered]@{ geradoEm = (Get-Date).ToString('s'); calendarios = [object[]]$status.ToArray(); eventos = [object[]]$eventos.ToArray() }
$tmp = "$ArqSaida.tmp"
[IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $saida -Depth 5), $Utf8)
Move-Item -Force -LiteralPath $tmp -Destination $ArqSaida
