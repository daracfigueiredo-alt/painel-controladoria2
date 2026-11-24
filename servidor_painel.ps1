# Servidor local do painel da Controladoria (somente neste computador: http://localhost:8080)
# Serve os arquivos da pasta "painel". Feche esta janela para desligar.
$ErrorActionPreference = 'Stop'
$raiz = Join-Path $PSScriptRoot 'painel'
$porta = 8080
$tipos = @{ '.html'='text/html; charset=utf-8'; '.js'='text/javascript; charset=utf-8'; '.css'='text/css; charset=utf-8';
            '.json'='application/json'; '.svg'='image/svg+xml'; '.png'='image/png'; '.ico'='image/x-icon';
            '.woff2'='font/woff2'; '.woff'='font/woff'; '.map'='application/json' }
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:$porta/")
try { $l.Start() } catch { Write-Host "Não foi possível usar a porta $porta (já está em uso?). $_"; Read-Host 'Enter para sair'; exit 1 }
Write-Host "Painel no ar: http://localhost:$porta  (feche esta janela para desligar)"
Start-Process "http://localhost:$porta/"
$raizCompleta = [IO.Path]::GetFullPath($raiz)
while ($l.IsListening) {
  $c = $l.GetContext()
  try {
    $caminho = [Uri]::UnescapeDataString($c.Request.Url.AbsolutePath).TrimStart('/')
    if ($caminho -eq '' -or $caminho.EndsWith('/')) { $caminho += 'index.html' }
    $arq = [IO.Path]::GetFullPath((Join-Path $raiz $caminho))
    if (-not $arq.StartsWith($raizCompleta) -or -not (Test-Path $arq -PathType Leaf)) {
      $c.Response.StatusCode = 404; $b = [Text.Encoding]::UTF8.GetBytes('404')
    } else {
      $ext = [IO.Path]::GetExtension($arq).ToLower()
      $c.Response.ContentType = $(if ($tipos.ContainsKey($ext)) { $tipos[$ext] } else { 'application/octet-stream' })
      $c.Response.Headers.Add('Cache-Control', 'no-store')
      $b = [IO.File]::ReadAllBytes($arq)
    }
    $c.Response.ContentLength64 = $b.Length
    $c.Response.OutputStream.Write($b, 0, $b.Length)
  } catch { } finally { $c.Response.Close() }
}
