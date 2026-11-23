@echo off
title Agenda de Compromissos - liberar botoes de adiar no celular
rem ------------------------------------------------------------------------------
rem  Executar UMA UNICA VEZ, como ADMINISTRADOR (botao direito > Executar como administrador).
rem  Permite que o botao "Lembrar N min antes" da notificacao no celular chegue ao servidor
rem  da agenda pela rede local (Wi-Fi). A agenda em si continua acessivel so neste computador:
rem  pela rede o servidor aceita apenas o comando de adiar, protegido por um codigo secreto.
rem
rem  Para desfazer (como administrador):
rem    netsh http delete urlacl url=http://+:8085/
rem    netsh advfirewall firewall delete rule name="Agenda de Compromissos (8085)"
rem ------------------------------------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
  echo.
  echo  Este arquivo precisa ser executado como ADMINISTRADOR.
  echo  Clique com o botao direito sobre ele e escolha "Executar como administrador".
  echo.
  pause
  exit /b 1
)

echo Liberando o endereco http://+:8085/ para o servidor da agenda...
netsh http delete urlacl url=http://+:8085/ >nul 2>&1
netsh http add urlacl url=http://+:8085/ sddl=D:(A;;GX;;;WD)

echo Criando regra no Firewall do Windows (porta 8085, redes privada e de dominio)...
netsh advfirewall firewall delete rule name="Agenda de Compromissos (8085)" >nul 2>&1
netsh advfirewall firewall add rule name="Agenda de Compromissos (8085)" dir=in action=allow protocol=TCP localport=8085 profile=private,domain

echo.
echo Pronto. Agora feche e abra novamente o iniciar.bat.
echo.
pause
